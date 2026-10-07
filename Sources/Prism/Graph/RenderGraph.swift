// RenderGraph.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal

/// Identifies a node. Also identifies the texture that node produces: every node
/// has exactly one output resource, so edges between nodes *are* resource dependencies.
struct NodeID: Hashable, Comparable, Sendable, CustomStringConvertible {
    var rawValue: Int
    static func < (a: NodeID, b: NodeID) -> Bool { a.rawValue < b.rawValue }
    var description: String { "#\(rawValue)" }
}

/// Size and format of a texture resource. Pool compatibility (Phase 5) is keyed on this.
struct TextureDescriptor: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: MTLPixelFormat = .rgba8Unorm
}

/// A per-pixel color operation that can be fused with its neighbours into one pass.
/// Mirrors `PointOp` in Color.metal.
struct PointwiseOp: Sendable {
    enum Code: Int32, Sendable { case exposure = 0, contrast, saturation, temperature, vignette }
    var code: Code
    var a: Float
    var b: Float = 0
    var name: String
}

/// How a separable blur pass tiles its input in threadgroup memory. The threadgroup shape depends
/// on the blur radius (a tile needs `2·radius` extra texels along the blur axis) and on what the
/// GPU allows, so it is computed at encode time from the pipeline's limits.
enum BlurTiling: Sendable, Equatable {
    case horizontal(radius: Int)
    case vertical(radius: Int)

    /// Threadgroup memory budget in `float4` elements (32 KiB, the Apple GPU limit).
    static let tileElements = 2048
    /// Adjacent outputs each thread computes along the blur axis (must match `kOutputsPerThread`
    /// in Blur.metal).
    static let outputsPerThread = 4

    struct Configuration: Equatable {
        /// Threads per threadgroup.
        var width: Int
        var height: Int
        var memoryBytes: Int
    }

    /// The grid of threads for an image: one thread per `outputsPerThread` pixels along the axis.
    func gridSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let n = Self.outputsPerThread
        switch self {
        case .horizontal: return ((width + n - 1) / n, height)
        case .vertical: return (width, (height + n - 1) / n)
        }
    }

    /// Chooses the threadgroup shape, or `nil` if no tile fits.
    func configuration(maxThreads: Int) -> Configuration? {
        let n = Self.outputsPerThread
        switch self {
        case .horizontal(let radius):
            // 32 threads x n outputs span a tile row of `32·n + 2·radius` texels; stack rows that fit.
            let width = 32
            let rowElements = width * n + 2 * radius
            let rows = min(Self.tileElements / rowElements, 8, maxThreads / width)
            return rows >= 1 ? Configuration(width: width, height: rows, memoryBytes: rows * rowElements * 16) : nil
        case .vertical(let radius):
            // `height` threads x n outputs span a tile column of `height·n + 2·radius` texels; use the
            // widest tile that fits.
            let height = Self.verticalThreads
            for width in [32, 16, 8, 4, 2, 1] where width * (height * n + 2 * radius) <= Self.tileElements && width * height <= maxThreads {
                return Configuration(width: width, height: height, memoryBytes: width * (height * n + 2 * radius) * 16)
            }
            return nil
        }
    }

    /// Threads along the blur axis in a vertical tile. Chosen by sweeping 4, 8, 16 and 32 at 4K
    /// (see OPTIMIZATION.md): 16 and 32 were equally fast and ~10–25% ahead of 8; 16 keeps the
    /// threadgroup at 256 threads or fewer.
    static let verticalThreads = 16
}

/// One compute dispatch over the node's whole output.
///
/// Binding convention: inputs are bound to `texture(0)` … `texture(n-1)` in order,
/// the output to `texture(n)`, and the LUT (if any) to `texture(n+1)`. Uniforms (if any)
/// are bound to `buffer(0)` and constant tables (if any) to `buffer(1)`; both are
/// passed with `setBytes`, so each must stay under Metal's 4 KB limit.
struct ComputePass: Sendable {
    var kernel: String
    var uniforms: [UInt8]
    /// Read-only table, e.g. Gaussian weights.
    var constants: [UInt8] = []
    var lut: LUT3D?
    /// True for per-pixel kernels that read the same coordinates they write.
    /// Resize-style kernels set this false.
    var inputsMatchOutputSize = true
    /// True when, for these parameters, the output equals input 0 exactly. Such passes
    /// are removed by ``IdentityElimination`` (and still run correctly when optimization is off).
    var isIdentity = false
    /// Set on per-pixel color operations: the pass is a single `PointwiseOp` that fusion may merge
    /// with adjacent ones.
    var pointwise: PointwiseOp?
    /// Names of the operations a fused pass replaces (empty for ordinary passes).
    var fusedFrom: [String] = []
    /// Set on tiled blur passes; selects the threadgroup shape and memory at encode time.
    var tiling: BlurTiling?

    init<Uniforms: BitwiseCopyable>(kernel: String, uniforms: Uniforms, isIdentity: Bool = false) {
        self.kernel = kernel
        self.uniforms = withUnsafeBytes(of: uniforms) { Array($0) }
        self.isIdentity = isIdentity
    }

    init<Uniforms: BitwiseCopyable>(kernel: String, uniforms: Uniforms, constants: [Float], isIdentity: Bool = false) {
        self.init(kernel: kernel, uniforms: uniforms, isIdentity: isIdentity)
        self.constants = constants.withUnsafeBytes { Array($0) }
    }

    init(kernel: String) {
        self.kernel = kernel
        self.uniforms = []
    }
}

/// A DAG of GPU work. A value type: building, validating and (later) rewriting a graph
/// never touches the GPU.
struct RenderGraph: Sendable {
    struct Node: Sendable {
        enum Work: Sendable {
            /// An externally supplied texture (the image entering the pipeline).
            case source
            case compute(ComputePass)
        }
        var id: NodeID
        var name: String
        var work: Work
        var inputs: [NodeID]
        var output: TextureDescriptor
    }

    private(set) var nodes: [Node]
    private(set) var output: NodeID?

    init(nodes: [Node] = [], output: NodeID? = nil) {
        self.nodes = nodes
        self.output = output
    }

    // MARK: Construction

    mutating func addSource(_ name: String, descriptor: TextureDescriptor) -> NodeID {
        append(name: name, work: .source, inputs: [], output: descriptor)
    }

    mutating func addPass(
        _ name: String, _ pass: ComputePass, inputs: [NodeID], output: TextureDescriptor
    ) -> NodeID {
        append(name: name, work: .compute(pass), inputs: inputs, output: output)
    }

    mutating func setOutput(_ id: NodeID) { output = id }

    private mutating func append(name: String, work: Node.Work, inputs: [NodeID], output: TextureDescriptor) -> NodeID {
        let id = NodeID(rawValue: nodes.count)
        nodes.append(Node(id: id, name: name, work: work, inputs: inputs, output: output))
        return id
    }

    func node(_ id: NodeID) -> Node { nodes[id.rawValue] }

    /// Builds a new graph without the `removed` nodes, renumbering the rest densely (so the
    /// `id == index` invariant holds). A reference to a removed node is redirected through
    /// `redirect` (following chains) to the node that replaces it.
    ///
    /// - Returns: the new graph and a map from every *old* id to the new id of the node that
    ///   now stands for it (a removed node maps to its replacement).
    func rewritten(
        removing removed: Set<NodeID>, redirect: [NodeID: NodeID] = [:]
    ) -> (graph: RenderGraph, map: [NodeID: NodeID]) {
        func resolve(_ id: NodeID) -> NodeID {
            var id = id
            while let next = redirect[id] { id = next }
            return id
        }
        var newID: [NodeID: NodeID] = [:]
        for node in nodes where !removed.contains(node.id) {
            newID[node.id] = NodeID(rawValue: newID.count)
        }
        var rebuilt: [Node] = []
        for node in nodes where !removed.contains(node.id) {
            var copy = node
            copy.id = newID[node.id]!
            copy.inputs = node.inputs.map { newID[resolve($0)]! }
            rebuilt.append(copy)
        }
        var map = newID
        for node in nodes where removed.contains(node.id) {
            if let target = newID[resolve(node.id)] { map[node.id] = target }
        }
        return (RenderGraph(nodes: rebuilt, output: output.flatMap { map[$0] }), map)
    }

    // MARK: Validation

    /// Checks structural and resource validity. Cycle detection lives in the planner
    /// because it falls out of topological sorting; `validate` runs both.
    func validate() throws {
        guard let output else { throw PrismError.invalidGraph(reason: "no output node set") }
        guard nodes.indices.contains(output.rawValue) else {
            throw PrismError.invalidGraph(reason: "output \(output) does not exist")
        }
        for (index, node) in nodes.enumerated() {
            guard node.id.rawValue == index else {
                throw PrismError.invalidGraph(reason: "node at index \(index) has id \(node.id)")
            }
            for input in node.inputs where !nodes.indices.contains(input.rawValue) {
                throw PrismError.invalidGraph(reason: "'\(node.name)' reads missing node \(input)")
            }
            guard node.output.width > 0, node.output.height > 0 else {
                throw PrismError.incompatibleResources(
                    reason: "'\(node.name)' outputs a \(node.output.width)×\(node.output.height) texture")
            }
            switch node.work {
            case .source:
                if !node.inputs.isEmpty {
                    throw PrismError.invalidGraph(reason: "source '\(node.name)' must not have inputs")
                }
            case .compute(let pass):
                if node.inputs.isEmpty {
                    throw PrismError.invalidGraph(reason: "'\(node.name)' has no inputs")
                }
                for input in node.inputs {
                    let source = self.node(input)
                    if source.output.pixelFormat != node.output.pixelFormat {
                        throw PrismError.incompatibleResources(
                            reason: "'\(node.name)' reads \(source.output.pixelFormat) from '\(source.name)' but writes \(node.output.pixelFormat)")
                    }
                    if pass.inputsMatchOutputSize,
                       source.output.width != node.output.width || source.output.height != node.output.height {
                        throw PrismError.incompatibleResources(
                            reason: "'\(node.name)' needs \(node.output.width)×\(node.output.height) input but '\(source.name)' is \(source.output.width)×\(source.output.height)")
                    }
                }
            }
        }
        _ = try ExecutionPlan(graph: self)   // rejects cycles
    }
}
