// OptimizerTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Testing
@testable import Prism

private let d = TextureDescriptor(width: 8, height: 8)

private func pass(_ kernel: String = "prism_invert", identity: Bool = false) -> ComputePass {
    var p = ComputePass(kernel: kernel); p.isIdentity = identity; return p
}

private func optimize(_ g: RenderGraph, _ options: OptimizationOptions = .all) -> GraphOptimizer.Result {
    GraphOptimizer(options: options).optimize(g)
}

/// A symbolic evaluation of what a node computes: identity passes are transparent, others
/// are named applications. Two graphs computing the same thing have equal output expressions.
private func expression(_ g: RenderGraph, _ id: NodeID, _ memo: inout [NodeID: String]) -> String {
    if let cached = memo[id] { return cached }
    let node = g.node(id)
    let result: String
    switch node.work {
    case .source: result = node.name
    case .compute(let p):
        if p.isIdentity, let first = node.inputs.first, g.node(first).output == node.output {
            result = expression(g, first, &memo)
        } else {
            result = "\(node.name)(\(node.inputs.map { expression(g, $0, &memo) }.joined(separator: ",")))"
        }
    }
    memo[id] = result
    return result
}

private func outputExpression(_ g: RenderGraph) -> String {
    var memo: [NodeID: String] = [:]
    return expression(g, g.output!, &memo)
}

@Suite("Graph optimizer")
struct GraphOptimizerTests {
    @Test("Identity passes are removed and consumers rewired")
    func identityChain() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", pass(identity: true), inputs: [input], output: d)
        let b = g.addPass("B", pass(), inputs: [a], output: d)
        let c = g.addPass("C", pass(identity: true), inputs: [b], output: d)
        let e = g.addPass("E", pass(identity: true), inputs: [c], output: d)
        g.setOutput(e)

        let r = optimize(g)
        try r.graph.validate()
        #expect(r.graph.nodes.map(\.name) == ["Input", "B"])
        #expect(r.graph.node(NodeID(rawValue: 1)).inputs == [NodeID(rawValue: 0)])
        #expect(r.graph.output == NodeID(rawValue: 1), "an identity at the output hands the output to its input")
        #expect(r.removedPasses == 3)
        #expect(r.map[a] == r.map[input] && r.map[e] == r.map[b], "removed nodes map to their replacements")
    }

    @Test("An all-identity graph collapses to its source")
    func allIdentity() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        var current = input
        for i in 0..<5 { current = g.addPass("I\(i)", pass(identity: true), inputs: [current], output: d) }
        g.setOutput(current)
        let r = optimize(g)
        #expect(r.graph.nodes.count == 1 && r.graph.output == NodeID(rawValue: 0))
        try r.graph.validate()
    }

    @Test("An identity flagged on a pass whose output differs from its input is kept")
    func mismatchedIdentityIsKept() throws {
        var resize = pass(identity: true); resize.inputsMatchOutputSize = false
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        g.setOutput(g.addPass("Resize", resize, inputs: [input], output: .init(width: 4, height: 4)))
        #expect(optimize(g).graph.nodes.count == 2)
    }

    @Test("A multi-input identity forwards its first input; the rest becomes dead")
    func multiInputIdentity() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let blur = g.addPass("Blur", pass(), inputs: [input], output: d)
        g.setOutput(g.addPass("Combine", pass(identity: true), inputs: [input, blur], output: d))
        let r = optimize(g)
        #expect(r.graph.nodes.map(\.name) == ["Input"], "Combine removed as identity, Blur as dead")
        #expect(r.removedPasses == 2)
    }

    @Test("Dead nodes are removed, sources are kept, ids are dense")
    func deadNodes() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let unusedSource = g.addSource("Unused", descriptor: d)
        let live = g.addPass("Live", pass(), inputs: [input], output: d)
        let dead1 = g.addPass("Dead1", pass(), inputs: [unusedSource], output: d)
        _ = g.addPass("Dead2", pass(), inputs: [dead1, live], output: d)
        g.setOutput(g.addPass("Out", pass(), inputs: [live], output: d))

        let r = optimize(g)
        try r.graph.validate()
        #expect(r.graph.nodes.map(\.name) == ["Input", "Unused", "Live", "Out"])
        #expect(r.removedPasses == 2)
        #expect(r.map[dead1] == nil, "dead nodes have no replacement")
    }

    @Test("Options select the passes; .none changes nothing")
    func options() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let id = g.addPass("Id", pass(identity: true), inputs: [input], output: d)
        _ = g.addPass("Dead", pass(), inputs: [input], output: d)
        g.setOutput(g.addPass("Out", pass(), inputs: [id], output: d))

        #expect(optimize(g, .none).graph.nodes.count == 4)
        #expect(optimize(g, .identityElimination).graph.nodes.map(\.name) == ["Input", "Dead", "Out"])
        #expect(optimize(g, .deadNodeElimination).graph.nodes.map(\.name) == ["Input", "Id", "Out"])
        #expect(optimize(g, .all).graph.nodes.map(\.name) == ["Input", "Out"])
    }

    @Test("Optimizing is idempotent")
    func idempotent() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", pass(identity: true), inputs: [input], output: d)
        let b = g.addPass("B", pass(), inputs: [a], output: d)
        _ = g.addPass("Dead", pass(), inputs: [b], output: d)
        g.setOutput(b)
        let once = optimize(g).graph
        let twice = optimize(once)
        #expect(twice.removedPasses == 0 && twice.graph.nodes.map(\.name) == once.nodes.map(\.name))
    }

    @Test("Random DAGs: optimization preserves the output's symbolic expression and validity")
    func randomGraphsPreserveSemantics() throws {
        var rng = SplitMix64(seed: 0xFACADE)
        var totalRemoved = 0
        for trial in 0..<500 {
            var g = RenderGraph()
            var ids = (0..<Int.random(in: 1...2, using: &rng)).map { g.addSource("S\($0)", descriptor: d) }
            for n in 0..<Int.random(in: 1...30, using: &rng) {
                let fan = Int.random(in: 1...3, using: &rng)
                let inputs = (0..<fan).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] }
                let identity = Int.random(in: 0..<3, using: &rng) == 0
                ids.append(g.addPass("N\(n)", pass(identity: identity), inputs: inputs, output: d))
            }
            g.setOutput(ids[Int.random(in: 0..<ids.count, using: &rng)])
            try g.validate()

            let r = optimize(g)
            try r.graph.validate()
            #expect(outputExpression(r.graph) == outputExpression(g), "trial \(trial)")
            #expect(r.graph.nodes.count + r.removedPasses == g.nodes.count)
            // Nothing the output doesn't need survives, and no flagged identity does.
            for node in r.graph.nodes {
                if case .compute(let p) = node.work { #expect(!p.isIdentity, "trial \(trial): \(node.name) is an identity") }
            }
            #expect(optimize(r.graph).removedPasses == 0, "trial \(trial): not a fixed point")
            totalRemoved += r.removedPasses
        }
        #expect(totalRemoved > 500, "the generator should actually exercise removal")
    }
}

@Suite("Optimizer in the renderer", .enabled(if: hasMetal))
struct RendererOptimizationTests {
    private let src = testPixels(width: 41, height: 23)
    private var image: CGImage { makeImage(width: 41, height: 23, bytes: src) }

    private func neutral() -> [(String, any ImageOperation)] {
        let lut = try! LUT3D.identity(size: 5)
        return [("Exposure(0)", Exposure(0)), ("Contrast(1)", Contrast(1)), ("Saturation(1)", Saturation(1)),
                ("Temperature(0)", Temperature(0)), ("Vignette(0)", Vignette(amount: 0)),
                ("Blur(0)", GaussianBlur(radius: 0)), ("Sharpen(0)", Sharpen(amount: 0)),
                ("Resize(same)", Resize(width: 41, height: 23)), ("LUT(0)", LUTGrade(lut, intensity: 0))]
    }

    @Test("Neutral operations cost no GPU passes when optimization is on")
    func eliminated() async throws {
        let renderer = try Renderer()
        for (name, op) in neutral() {
            let r = try await ImagePipeline(operations: [op]).renderWithMetrics(image, using: renderer)
            #expect(r.metrics.nodes.isEmpty, "\(name) should be eliminated")
            #expect(r.metrics.eliminatedPasses > 0)
            #expect(try pixels(of: r.image) == src, "\(name)")
        }
        #expect(renderer.statistics.cachedPipelines == 0, "no kernel was even compiled")
    }

    @Test("Neutral kernels really are exact identities when not eliminated")
    func kernelsAreIdentities() async throws {
        let renderer = try Renderer(optimizations: .none)
        for (name, op) in neutral() {
            let r = try await ImagePipeline(operations: [op]).renderWithMetrics(image, using: renderer)
            #expect(!r.metrics.nodes.isEmpty && r.metrics.eliminatedPasses == 0, "\(name) should execute")
            // The LUT kernel round-trips color through float and may land 1 LSB away.
            #expect(maxError(try pixels(of: r.image), src) <= (name == "LUT(0)" ? 1 : 0), "\(name)")
        }
    }

    @Test("Sharpen(amount: 0) removes its blur passes as dead")
    func sharpenZero() async throws {
        let on = try await ImagePipeline { Sharpen(amount: 0) }.renderWithMetrics(image, using: try Renderer()).metrics
        #expect(on.nodes.isEmpty && on.eliminatedPasses == 3)
        let off = try await ImagePipeline { Sharpen(amount: 0) }.renderWithMetrics(image, using: try Renderer(optimizations: .none)).metrics
        #expect(off.nodes.count == 3 && off.eliminatedPasses == 0)
    }

    @Test("Optimized and unoptimized pipelines produce identical pixels")
    func sameResult() async throws {
        let ops = ImagePipeline {
            Exposure(0); Exposure(0.4); Contrast(1); GaussianBlur(radius: 0); Saturation(1.3)
            Sharpen(amount: 0); Sharpen(amount: 0.7); Vignette(amount: 0); Temperature(0.2); Resize(width: 41, height: 23)
        }
        let a = try await ops.renderWithMetrics(image, using: try Renderer(optimizations: noFusion))
        let b = try await ops.renderWithMetrics(image, using: try Renderer(optimizations: .none))
        #expect(try pixels(of: a.image) == pixels(of: b.image))
        #expect(a.metrics.nodes.count == 6 && b.metrics.nodes.count == 15, "\(a.metrics.nodes.count) vs \(b.metrics.nodes.count)")
        #expect(a.metrics.eliminatedPasses == 9)
        #expect(a.metrics.peakActiveTextures <= b.metrics.peakActiveTextures)
    }

    @Test("Eliminated passes show in the metrics description")
    func description() async throws {
        let m = try await ImagePipeline { Exposure(0); Contrast(1.2) }.renderWithMetrics(image, using: try Renderer()).metrics
        #expect(m.eliminatedPasses == 1 && m.description.contains("1 passes eliminated"))
    }

    @Test("Source textures stay correctly bound after ids are renumbered")
    func sourceRemapping() async throws {
        // The source is node 0 either way, but the output and consumers shift; run a graph
        // whose source is NOT the first node so remapping is actually exercised.
        let renderer = try Renderer()
        let input = RenderGraph.Node(id: NodeID(rawValue: 1), name: "Input", work: .source, inputs: [], output: .init(width: 41, height: 23))
        let deadEarly = RenderGraph.Node(id: NodeID(rawValue: 0), name: "DeadEarly", work: .compute(pass()), inputs: [NodeID(rawValue: 1)], output: .init(width: 41, height: 23))
        let inv = RenderGraph.Node(id: NodeID(rawValue: 2), name: "Inv", work: .compute(pass()), inputs: [NodeID(rawValue: 1)], output: .init(width: 41, height: 23))
        let graph = RenderGraph(nodes: [deadEarly, input, inv], output: NodeID(rawValue: 2))
        let texture = try CGImageInterop.makeTexture(from: image, context: renderer.context)
        let out = try await renderer.run(graph, sources: [NodeID(rawValue: 1): texture]) { CGImageInterop.readPixels(from: $0) }
        var expected = src
        for i in stride(from: 0, to: src.count, by: 4) { for c in 0..<3 { expected[i + c] = src[i + 3] - src[i + c] } }
        #expect(maxError(out, expected) <= 1)
    }
}
