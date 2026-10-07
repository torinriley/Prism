// GraphTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Testing
@testable import Prism

private let desc = TextureDescriptor(width: 8, height: 8)
private let pass = ComputePass(kernel: "prism_invert")

private func node(_ id: Int, _ name: String, inputs: [Int] = [], output: TextureDescriptor = desc) -> RenderGraph.Node {
    RenderGraph.Node(
        id: NodeID(rawValue: id), name: name,
        work: inputs.isEmpty ? .source : .compute(pass),
        inputs: inputs.map(NodeID.init(rawValue:)), output: output)
}

/// Input → A → (B, C) → D, the diamond from the design doc.
private func diamond() -> (RenderGraph, [String: NodeID]) {
    var g = RenderGraph()
    let input = g.addSource("Input", descriptor: desc)
    let a = g.addPass("A", pass, inputs: [input], output: desc)
    let b = g.addPass("B", pass, inputs: [a], output: desc)
    let c = g.addPass("C", pass, inputs: [a], output: desc)
    let d = g.addPass("D", pass, inputs: [b, c], output: desc)
    g.setOutput(d)
    return (g, ["Input": input, "A": a, "B": b, "C": c, "D": d])
}

@Suite("RenderGraph validation")
struct GraphValidationTests {
    @Test func validDiamondPasses() throws {
        try diamond().0.validate()
    }

    @Test func missingOutput() {
        var g = RenderGraph()
        _ = g.addSource("Input", descriptor: desc)
        #expect(throws: PrismError.invalidGraph(reason: "no output node set")) { try g.validate() }
    }

    @Test func outputOutOfRange() {
        let g = RenderGraph(nodes: [node(0, "Input")], output: NodeID(rawValue: 3))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func danglingInput() {
        let g = RenderGraph(nodes: [node(0, "Input"), node(1, "A", inputs: [7])], output: NodeID(rawValue: 1))
        #expect(throws: PrismError.invalidGraph(reason: "'A' reads missing node #7")) { try g.validate() }
    }

    @Test func cycle() {
        let g = RenderGraph(
            nodes: [node(0, "Input"), node(1, "A", inputs: [0, 3]), node(2, "B", inputs: [1]), node(3, "C", inputs: [2])],
            output: NodeID(rawValue: 3))
        #expect(throws: PrismError.invalidGraph(reason: "cycle involving A, B, C")) { try g.validate() }
    }

    @Test func selfLoop() {
        let g = RenderGraph(nodes: [node(0, "A", inputs: [0])], output: NodeID(rawValue: 0))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func sourceWithInputsIsRejected() {
        var n = node(1, "S", inputs: [0]); n.work = .source
        let g = RenderGraph(nodes: [node(0, "Input"), n], output: NodeID(rawValue: 1))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func passWithoutInputsIsRejected() {
        var n = node(0, "P"); n.work = .compute(pass)
        #expect(throws: PrismError.self) { try RenderGraph(nodes: [n], output: n.id).validate() }
    }

    @Test func mismatchedSizesAreIncompatible() {
        let big = TextureDescriptor(width: 16, height: 8)
        let g = RenderGraph(nodes: [node(0, "Input"), node(1, "A", inputs: [0], output: big)], output: NodeID(rawValue: 1))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func resizingPassesMaySizeDiffer() throws {
        var resize = pass; resize.inputsMatchOutputSize = false
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: desc)
        g.setOutput(g.addPass("Resize", resize, inputs: [input], output: .init(width: 3, height: 5)))
        try g.validate()
    }

    @Test func mismatchedFormatsAreIncompatible() {
        let f16 = TextureDescriptor(width: 8, height: 8, pixelFormat: .rgba16Float)
        let g = RenderGraph(nodes: [node(0, "Input"), node(1, "A", inputs: [0], output: f16)], output: NodeID(rawValue: 1))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func zeroSizedTextureIsRejected() {
        let g = RenderGraph(nodes: [node(0, "Input", output: .init(width: 0, height: 4))], output: NodeID(rawValue: 0))
        #expect(throws: PrismError.self) { try g.validate() }
    }

    @Test func nodeIdsMustMatchIndices() {
        let g = RenderGraph(nodes: [node(5, "Input")], output: NodeID(rawValue: 0))
        #expect(throws: PrismError.self) { try g.validate() }
    }
}

@Suite("ExecutionPlan")
struct ExecutionPlanTests {
    @Test func diamondOrderIsDeterministicAndRespectsDependencies() throws {
        let (g, ids) = diamond()
        let plan = try ExecutionPlan(graph: g)
        #expect(plan.order == [ids["Input"]!, ids["A"]!, ids["B"]!, ids["C"]!, ids["D"]!])
        for _ in 0..<50 { #expect(try ExecutionPlan(graph: g).order == plan.order) }
    }

    @Test func independentBranchesOrderBySmallestID() throws {
        // Declared out of dependency order: node 1 depends on node 3.
        let g = RenderGraph(
            nodes: [node(0, "Input"), node(1, "X", inputs: [3]), node(2, "Y", inputs: [0]), node(3, "Z", inputs: [0, 2])],
            output: NodeID(rawValue: 1))
        let order = try ExecutionPlan(graph: g).order.map(\.rawValue)
        #expect(order == [0, 2, 3, 1])
    }

    @Test func lifetimes() throws {
        let (g, ids) = diamond()
        let plan = try ExecutionPlan(graph: g)
        let last = { (n: String) in plan.lastUse[ids[n]!.rawValue] }
        #expect(last("Input") == 1)   // read by A at step 1
        #expect(last("A") == 3)       // read by B (2) and C (3)
        #expect(last("B") == 4)       // read by D
        #expect(last("C") == 4)
        #expect(last("D") == 5)       // graph output: live past the final step
    }

    @Test func unreadNodeDiesAtItsOwnStep() throws {
        var (g, _) = diamond()
        let dead = g.addPass("Dead", pass, inputs: [NodeID(rawValue: 0)], output: desc)
        let plan = try ExecutionPlan(graph: g)
        #expect(plan.lastUse[dead.rawValue] == plan.order.firstIndex(of: dead)!)
    }
}
