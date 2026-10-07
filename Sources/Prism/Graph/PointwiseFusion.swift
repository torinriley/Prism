// PointwiseFusion.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// Merges runs of per-pixel color operations into a single pass.
///
/// A run is a sequence of nodes where each is a `pointwise` pass reading exactly one input
/// (same size and format as its output) and each node but the last has exactly one consumer
/// (the next node) and is not the graph output. Anything else (a branch, a spatial pass, the
/// output, a LUT) ends the run, so fusion never changes which intermediate results exist
/// that something else reads.
///
/// The fused pass reads the run's first input once, applies every operation in registers
/// (each result clamped to [0, 1] exactly as in the standalone kernels), and writes once.
/// What changes versus running the passes separately is that results are no longer rounded
/// to 8 bits between operations, so the fused result is slightly *closer* to the ideal
/// value; it is not bit-identical to the unfused chain.
struct PointwiseFusion: GraphPass {
    let name = "pointwise fusion"

    /// Bounds the per-pixel loop and the constant buffer (32 × 16 B).
    static let maxChainLength = 32

    /// The chain kernel's pass for `ops` (layout mirrors `PointOp` / `ChainParams` in Color.metal).
    static func fusedPass(_ ops: [PointwiseOp]) -> ComputePass {
        var pass = ComputePass(kernel: "prism_pointwise_chain", uniforms: Int32(ops.count))
        pass.constants = ops.flatMap { op -> [UInt8] in
            withUnsafeBytes(of: (op.code.rawValue, op.a, op.b, Float(0))) { Array($0) }
        }
        pass.fusedFrom = ops.map(\.name)
        return pass
    }

    func run(_ graph: RenderGraph) -> (graph: RenderGraph, map: [NodeID: NodeID], removed: Int) {
        var uses = [Int](repeating: 0, count: graph.nodes.count)
        for node in graph.nodes { for input in node.inputs { uses[input.rawValue] += 1 } }
        if let output = graph.output { uses[output.rawValue] += 1 }   // the output is "consumed" by the caller

        func fusable(_ node: RenderGraph.Node) -> PointwiseOp? {
            guard case .compute(let pass) = node.work, let op = pass.pointwise,
                  node.inputs.count == 1, graph.node(node.inputs[0]).output == node.output else { return nil }
            return op
        }

        // Link each node to the fusable node that feeds it, if that feeder has no other consumer.
        var previous: [NodeID: NodeID] = [:]
        var next: [NodeID: NodeID] = [:]
        for node in graph.nodes where fusable(node) != nil {
            let feeder = node.inputs[0]
            if fusable(graph.node(feeder)) != nil, uses[feeder.rawValue] == 1 {
                previous[node.id] = feeder
                next[feeder] = node.id
            }
        }

        var replacements: [NodeID: RenderGraph.Node] = [:]
        var removed = Set<NodeID>()
        var redirect: [NodeID: NodeID] = [:]
        for head in graph.nodes where fusable(head) != nil && previous[head.id] == nil {
            var run = [head.id]
            while let n = next[run.last!] { run.append(n) }
            // Split overlong runs into bounded segments.
            for start in stride(from: 0, to: run.count, by: Self.maxChainLength) {
                let segment = Array(run[start..<min(start + Self.maxChainLength, run.count)])
                guard segment.count >= 2 else { continue }
                let first = graph.node(segment[0]), last = graph.node(segment.last!)
                let ops = segment.map { fusable(graph.node($0))! }

                var fused = last
                fused.inputs = first.inputs
                fused.work = .compute(Self.fusedPass(ops))
                fused.name = ops.count <= 3 ? ops.map(\.name).joined(separator: "+")
                                            : "Fused ×\(ops.count) (\(ops[0].name)…\(ops.last!.name))"
                replacements[last.id] = fused
                for id in segment.dropLast() { removed.insert(id); redirect[id] = last.id }
            }
        }
        guard !removed.isEmpty else {
            return (graph, Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.id) }), 0)
        }
        let modified = RenderGraph(nodes: graph.nodes.map { replacements[$0.id] ?? $0 }, output: graph.output)
        let result = modified.rewritten(removing: removed, redirect: redirect)
        return (result.graph, result.map, removed.count)
    }
}
