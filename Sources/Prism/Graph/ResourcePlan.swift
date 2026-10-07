// ResourcePlan.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// Static assignment of graph nodes to physical texture "slots" using the lifetimes
/// computed by ``ExecutionPlan``.
///
/// Two nodes may share a slot only if their live ranges are disjoint, where a node is live
/// from the step that writes it through the last step that reads it (inclusive). Because
/// the range is inclusive, a step's output never aliases one of its own inputs.
///
/// Slots are private to one render: they are leased from the shared ``TexturePool`` before
/// encoding and returned only after the GPU has finished with the command buffer.
/// Sharing a slot between two nodes inside one command buffer is safe because the encoder
/// is serial (each dispatch completes before the next begins) and Metal's default hazard
/// tracking orders the write-after-read.
struct ResourcePlan: Sendable {
    /// Slot index for every compute node. Source nodes (externally supplied) have no slot.
    let slot: [NodeID: Int]
    /// Descriptor of each slot; a slot is only shared by nodes with an identical descriptor.
    let slots: [TextureDescriptor]
    /// Number of compute nodes, i.e. how many textures a naive one-per-node scheme allocates.
    let logicalTextures: Int

    init(graph: RenderGraph, plan: ExecutionPlan) {
        var slot: [NodeID: Int] = [:]
        var slots: [TextureDescriptor] = []
        var free: [TextureDescriptor: [Int]] = [:]
        var logical = 0

        for (step, id) in plan.order.enumerated() {
            let node = graph.node(id)
            guard case .compute = node.work else { continue }
            logical += 1

            // Acquire before releasing this step's dying inputs: they are still being read.
            let assigned = free[node.output]?.popLast() ?? {
                slots.append(node.output)
                return slots.count - 1
            }()
            slot[id] = assigned

            // Release every texture whose last reader is this step (deduplicated; a node
            // may list the same input twice). An unread, non-output node dies at its own step.
            var dying = Set(node.inputs.filter { plan.lastUse[$0.rawValue] == step })
            if plan.lastUse[id.rawValue] == step { dying.insert(id) }
            for dead in dying.sorted() {
                guard let deadSlot = slot[dead] else { continue }   // sources own no slot
                free[graph.node(dead).output, default: []].append(deadSlot)
            }
        }
        self.slot = slot
        self.slots = slots
        self.logicalTextures = logical
    }
}
