// GraphLowering.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

extension RenderGraph {
    /// Lowers a linear operation list to a graph. Each operation contributes the steps of
    /// its plan; a step may read the operation's input again (Sharpen reads the original
    /// image after blurring it), so the result is a DAG, not necessarily a chain.
    ///
    /// - Returns: the graph and the id of its source node.
    static func chain(
        _ operations: [any ImageOperation], source descriptor: TextureDescriptor
    ) throws -> (graph: RenderGraph, source: NodeID) {
        var graph = RenderGraph()
        let source = graph.addSource("Input", descriptor: descriptor)
        var current = source
        var size = ImageSize(width: descriptor.width, height: descriptor.height)

        for operation in operations {
            let plan = try operation.plan(inputSize: size)
            guard !plan.steps.isEmpty else { continue }
            var ids: [NodeID] = []
            for (index, step) in plan.steps.enumerated() {
                let inputs = try step.inputs.map { input -> NodeID in
                    switch input {
                    case .operationInput: return current
                    case .step(let earlier):
                        guard earlier < index else {
                            throw PrismError.invalidGraph(reason: "\(operation.name) step \(index) reads step \(earlier)")
                        }
                        return ids[earlier]
                    }
                }
                let outSize = step.outputSize ?? size
                let name = step.name ?? (plan.steps.count > 1 ? "\(operation.name) [\(index + 1)/\(plan.steps.count)]" : operation.name)
                ids.append(graph.addPass(
                    name, step.pass, inputs: inputs,
                    output: TextureDescriptor(width: outSize.width, height: outSize.height, pixelFormat: descriptor.pixelFormat)))
            }
            current = ids.last!
            size = plan.steps.last!.outputSize ?? size
        }
        graph.setOutput(current)
        return (graph, source)
    }
}
