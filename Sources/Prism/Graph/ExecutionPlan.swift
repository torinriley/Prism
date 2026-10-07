// ExecutionPlan.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// A validated, ordered schedule for a ``RenderGraph``, plus resource lifetimes.
///
/// Planning is pure: it reads a graph and produces data. Optimization passes (Phase 7)
/// run on the graph *before* planning; the executor only ever consumes plans.
struct ExecutionPlan: Sendable {
    /// Every node, dependencies first.
    ///
    /// Deterministic: Kahn's algorithm, always taking the ready node with the smallest
    /// `NodeID`. The order therefore depends only on graph structure and insertion order,
    /// never on hashing or iteration order.
    let order: [NodeID]

    /// For each node (indexed by `NodeID`): the position in `order` of the last step that
    /// reads its texture, or its own position if nothing reads it. The graph output is
    /// pinned live past the end (`order.count`). After that step the texture is dead
    /// and may be recycled.
    let lastUse: [Int]

    /// Throws `PrismError.invalidGraph` if the graph contains a cycle or dangling edge.
    init(graph: RenderGraph) throws {
        let nodes = graph.nodes
        var pendingInputs = [Int](repeating: 0, count: nodes.count)
        var consumers = [[Int]](repeating: [], count: nodes.count)
        for node in nodes {
            for input in node.inputs {
                guard nodes.indices.contains(input.rawValue) else {
                    throw PrismError.invalidGraph(reason: "'\(node.name)' reads missing node \(input)")
                }
                pendingInputs[node.id.rawValue] += 1
                consumers[input.rawValue].append(node.id.rawValue)
            }
        }

        // `ready` stays sorted descending so `removeLast` yields the smallest id.
        var ready = nodes.indices.filter { pendingInputs[$0] == 0 }.sorted(by: >)
        var order: [NodeID] = []
        while let next = ready.popLast() {
            order.append(NodeID(rawValue: next))
            for consumer in consumers[next] {
                pendingInputs[consumer] -= 1
                if pendingInputs[consumer] == 0 {
                    let at = ready.firstIndex { $0 < consumer } ?? ready.endIndex
                    ready.insert(consumer, at: at)
                }
            }
        }
        guard order.count == nodes.count else {
            let stuck = nodes.indices.filter { pendingInputs[$0] > 0 }.map { nodes[$0].name }
            throw PrismError.invalidGraph(reason: "cycle involving \(stuck.joined(separator: ", "))")
        }

        var position = [Int](repeating: 0, count: nodes.count)
        for (step, id) in order.enumerated() { position[id.rawValue] = step }
        var lastUse = position
        for node in nodes {
            for input in node.inputs {
                lastUse[input.rawValue] = max(lastUse[input.rawValue], position[node.id.rawValue])
            }
        }
        if let output = graph.output { lastUse[output.rawValue] = order.count }
        self.order = order
        self.lastUse = lastUse
    }
}
