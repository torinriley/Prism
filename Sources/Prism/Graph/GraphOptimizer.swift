// GraphOptimizer.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// Optimizations the renderer may apply to a graph before planning it.
///
/// Every pass preserves what the graph computes; the options exist so benchmarks (and
/// anyone debugging) can compare optimized and unoptimized execution.
public struct OptimizationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Remove passes that are mathematically neutral for their parameters (`Exposure(0)`, …).
    public static let identityElimination = OptimizationOptions(rawValue: 1 << 0)
    /// Remove passes whose results never reach the output.
    public static let deadNodeElimination = OptimizationOptions(rawValue: 1 << 1)

    /// Merge runs of per-pixel color operations into one pass. Unlike the other optimizations
    /// this changes pixel values slightly (never beyond rounding): results are no longer rounded
    /// to 8 bits between the fused operations, so they are closer to the exact value.
    public static let pointwiseFusion = OptimizationOptions(rawValue: 1 << 2)

    public static let all: OptimizationOptions = [.identityElimination, .deadNodeElimination, .pointwiseFusion]
    public static let none: OptimizationOptions = []
}

/// A graph-to-graph rewrite. Passes run before planning and know nothing about the GPU.
protocol GraphPass {
    var name: String { get }
    /// Returns the rewritten graph, the old→new id map, and how many nodes were removed.
    func run(_ graph: RenderGraph) -> (graph: RenderGraph, map: [NodeID: NodeID], removed: Int)
}

/// Removes identity passes, redirecting their consumers to the pass's first input.
///
/// Only removes a pass if its output descriptor equals that input's, so a flagged pass can
/// never change the size or format of what flows downstream.
struct IdentityElimination: GraphPass {
    let name = "identity elimination"

    func run(_ graph: RenderGraph) -> (graph: RenderGraph, map: [NodeID: NodeID], removed: Int) {
        var removed = Set<NodeID>()
        var redirect: [NodeID: NodeID] = [:]
        for node in graph.nodes {
            guard case .compute(let pass) = node.work, pass.isIdentity,
                  let input = node.inputs.first,
                  graph.node(input).output == node.output else { continue }
            removed.insert(node.id)
            redirect[node.id] = input
        }
        let result = graph.rewritten(removing: removed, redirect: redirect)
        return (result.graph, result.map, removed.count)
    }
}

/// Removes compute passes the output does not depend on. Source nodes are always kept: the
/// caller supplied a texture for each, and keeping them keeps that contract simple.
struct DeadNodeElimination: GraphPass {
    let name = "dead node elimination"

    func run(_ graph: RenderGraph) -> (graph: RenderGraph, map: [NodeID: NodeID], removed: Int) {
        guard let output = graph.output else { return (graph, identityMap(graph), 0) }
        var live = Set<NodeID>()
        var stack = [output]
        while let id = stack.popLast() {
            guard live.insert(id).inserted else { continue }
            stack += graph.node(id).inputs
        }
        let dead = Set(graph.nodes.filter { node in
            if case .compute = node.work { return !live.contains(node.id) }
            return false
        }.map(\.id))
        let result = graph.rewritten(removing: dead)
        return (result.graph, result.map, dead.count)
    }

    private func identityMap(_ graph: RenderGraph) -> [NodeID: NodeID] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.id) })
    }
}

struct GraphOptimizer {
    var options: OptimizationOptions

    struct Result {
        var graph: RenderGraph
        /// Old node id → id of the node that now stands for it.
        var map: [NodeID: NodeID]
        var removedPasses: Int
    }

    func optimize(_ graph: RenderGraph) -> Result {
        // Identity elimination first: it can orphan nodes (Sharpen's blur once its combine
        // step is gone), which dead-node elimination then removes.
        var passes: [any GraphPass] = []
        if options.contains(.identityElimination) { passes.append(IdentityElimination()) }
        if options.contains(.deadNodeElimination) { passes.append(DeadNodeElimination()) }
        // Last: neutral stages must be gone first, or they would split chains.
        if options.contains(.pointwiseFusion) { passes.append(PointwiseFusion()) }

        var result = Result(graph: graph, map: Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.id) }), removedPasses: 0)
        for pass in passes {
            let step = pass.run(result.graph)
            // Compose: original id → previous id → new id.
            result.map = result.map.compactMapValues { step.map[$0] }
            result.graph = step.graph
            result.removedPasses += step.removed
        }
        return result
    }
}
