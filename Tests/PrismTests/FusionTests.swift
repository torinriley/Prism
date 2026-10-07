// FusionTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

private let d = TextureDescriptor(width: 8, height: 8)

private func point(_ name: String, _ code: PointwiseOp.Code = .contrast, identity: Bool = false) -> ComputePass {
    var p = ComputePass(kernel: "prism_contrast", uniforms: Float(1)); p.isIdentity = identity
    p.pointwise = PointwiseOp(code: code, a: 1, name: name)
    return p
}

private func plain(_ kernel: String = "prism_blur_horizontal") -> ComputePass { ComputePass(kernel: kernel) }

private func fuse(_ g: RenderGraph) -> GraphOptimizer.Result {
    GraphOptimizer(options: .pointwiseFusion).optimize(g)
}

private func fusedPasses(_ g: RenderGraph) -> [RenderGraph.Node] {
    g.nodes.filter { if case .compute(let p) = $0.work { !p.fusedFrom.isEmpty } else { false } }
}

@Suite("Pointwise fusion: structure")
struct FusionStructureTests {
    private func chain(_ names: [String], from input: NodeID, in g: inout RenderGraph) -> NodeID {
        var current = input
        for name in names { current = g.addPass(name, point(name), inputs: [current], output: d) }
        return current
    }

    @Test("A run of per-pixel passes becomes one pass reading the run's input")
    func basicRun() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        g.setOutput(chain(["A", "B", "C", "D"], from: input, in: &g))
        let r = fuse(g)
        try r.graph.validate()
        #expect(r.graph.nodes.map(\.name) == ["Input", "Fused ×4 (A…D)"])
        let fused = fusedPasses(r.graph)[0]
        #expect(fused.inputs == [NodeID(rawValue: 0)] && r.graph.output == fused.id)
        guard case .compute(let pass) = fused.work else { Issue.record("not compute"); return }
        #expect(pass.kernel == "prism_pointwise_chain" && pass.fusedFrom == ["A", "B", "C", "D"])
        #expect(pass.constants.count == 4 * 16 && pass.uniforms == withUnsafeBytes(of: Int32(4)) { Array($0) })
        #expect(r.removedPasses == 3)
        #expect(r.map[NodeID(rawValue: 1)] == fused.id, "an interior node maps to the fused pass")
    }

    @Test("Short runs are named after their operations")
    func naming() {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        var current = g.addPass("Exposure", point("Exposure"), inputs: [input], output: d)
        current = g.addPass("Contrast", point("Contrast"), inputs: [current], output: d)
        g.setOutput(current)
        #expect(fuse(g).graph.nodes.last?.name == "Exposure+Contrast")
    }

    @Test("A single per-pixel pass is left alone")
    func singleUnchanged() {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        g.setOutput(g.addPass("A", point("A"), inputs: [input], output: d))
        let r = fuse(g)
        #expect(r.removedPasses == 0 && r.graph.nodes.map(\.name) == ["Input", "A"])
    }

    @Test("Non-pointwise passes end a run")
    func spatialBreaksRun() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        var c = chain(["A", "B"], from: input, in: &g)
        c = g.addPass("BlurH", plain(), inputs: [c], output: d)
        c = g.addPass("BlurV", plain("prism_blur_vertical"), inputs: [c], output: d)
        g.setOutput(chain(["C", "D", "E"], from: c, in: &g))
        let r = fuse(g)
        try r.graph.validate()
        #expect(r.graph.nodes.map(\.name) == ["Input", "A+B", "BlurH", "BlurV", "C+D+E"])
        #expect(r.removedPasses == 3)
    }

    @Test("A node read by two consumers is not fused into either")
    func branchNotFused() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", point("A"), inputs: [input], output: d)
        let b = g.addPass("B", point("B"), inputs: [a], output: d)
        let c = g.addPass("C", point("C"), inputs: [a], output: d)
        g.setOutput(g.addPass("Mix", plain("prism_mix"), inputs: [b, c], output: d))
        let r = fuse(g)
        #expect(r.removedPasses == 0 && r.graph.nodes.count == 5)
    }

    @Test("The same input listed twice counts as two consumers")
    func duplicateInput() {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", point("A"), inputs: [input], output: d)
        g.setOutput(g.addPass("Mix", plain("prism_mix"), inputs: [a, a], output: d))
        #expect(fuse(g).removedPasses == 0)
    }

    @Test("The graph output may end a run, but is never fused into something later")
    func outputBoundary() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", point("A"), inputs: [input], output: d)
        let b = g.addPass("B", point("B"), inputs: [a], output: d)
        _ = g.addPass("C", point("C"), inputs: [b], output: d)   // also reads B, which is the output
        g.setOutput(b)
        let r = fuse(g)
        try r.graph.validate()
        #expect(r.graph.nodes.map(\.name) == ["Input", "A+B", "C"], "A+B fuse; C stays because B is also the output")
        #expect(r.graph.output == NodeID(rawValue: 1))
    }

    @Test("Passes whose size or format changes are not fused")
    func descriptorChange() {
        var resize = point("R"); resize.inputsMatchOutputSize = false
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", point("A"), inputs: [input], output: d)
        g.setOutput(g.addPass("R", resize, inputs: [a], output: .init(width: 4, height: 4)))
        #expect(fuse(g).removedPasses == 0)
    }

    @Test("Long runs split into segments of at most 32")
    func longRun() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        g.setOutput(chain((0..<70).map { "N\($0)" }, from: input, in: &g))
        let r = fuse(g)
        try r.graph.validate()
        let fused = fusedPasses(r.graph)
        #expect(fused.count == 3)
        #expect(fused.map { n -> Int in if case .compute(let p) = n.work { p.fusedFrom.count } else { 0 } } == [32, 32, 6])
        #expect(r.graph.nodes.count == 4 && r.removedPasses == 67)
        // Segments chain: each reads the previous segment's output.
        #expect(fused[1].inputs == [fused[0].id] && fused[2].inputs == [fused[1].id])
    }

    @Test("Fusion is idempotent, and runs after identity elimination so neutral stages don't split chains")
    func idempotentAndOrdering() throws {
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", point("A"), inputs: [input], output: d)
        let neutral = g.addPass("N", point("N", identity: true), inputs: [a], output: d)
        g.setOutput(g.addPass("B", point("B"), inputs: [neutral], output: d))

        #expect(GraphOptimizer(options: .pointwiseFusion).optimize(g).graph.nodes.map(\.name) == ["Input", "A+N+B"],
                "fusion alone fuses the neutral stage too (it is a real, if neutral, operation)")
        let all = GraphOptimizer(options: .all).optimize(g)
        #expect(all.graph.nodes.map(\.name) == ["Input", "A+B"])
        #expect(GraphOptimizer(options: .all).optimize(all.graph).removedPasses == 0)
    }

    @Test("Random DAGs: fusion preserves what the output computes")
    func randomGraphsPreserveSemantics() throws {
        var rng = SplitMix64(seed: 0xF05ED)
        var fusedAny = 0
        for trial in 0..<500 {
            var g = RenderGraph()
            var ids = [g.addSource("S0", descriptor: d)]
            for n in 0..<Int.random(in: 1...40, using: &rng) {
                let name = "N\(n)"
                let kind = Int.random(in: 0..<10, using: &rng)
                if kind < 6 {      // per-pixel, single input; biased to extend recent nodes so runs form
                    let from = Int.random(in: 0..<3, using: &rng) == 0 ? ids[Int.random(in: 0..<ids.count, using: &rng)] : ids.last!
                    ids.append(g.addPass(name, point(name), inputs: [from], output: d))
                } else if kind < 8 {
                    ids.append(g.addPass(name, plain(), inputs: [ids.last!], output: d))
                } else {
                    let inputs = (0..<2).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] }
                    ids.append(g.addPass(name, plain("prism_mix"), inputs: inputs, output: d))
                }
            }
            g.setOutput(ids[Int.random(in: 0..<ids.count, using: &rng)])
            try g.validate()

            let r = fuse(g)
            try r.graph.validate()
            #expect(symbolic(r.graph) == symbolic(g), "trial \(trial)")
            #expect(fuse(r.graph).removedPasses == 0, "trial \(trial): not a fixed point")
            fusedAny += r.removedPasses
        }
        #expect(fusedAny > 300, "the generator should exercise fusion")
    }

    /// Fused passes expand to the nested application of their operations.
    private func symbolic(_ g: RenderGraph) -> String {
        var memo: [NodeID: String] = [:]
        func expr(_ id: NodeID) -> String {
            if let m = memo[id] { return m }
            let node = g.node(id)
            var result: String
            switch node.work {
            case .source: result = node.name
            case .compute(let p):
                let inputs = node.inputs.map(expr)
                if p.fusedFrom.isEmpty {
                    result = "\(node.name)(\(inputs.joined(separator: ",")))"
                } else {
                    result = inputs[0]
                    for op in p.fusedFrom { result = "\(op)(\(result))" }
                }
            }
            memo[id] = result
            return result
        }
        return expr(g.output!)
    }
}

@Suite("Pointwise fusion: numerics", .enabled(if: hasMetal))
struct FusionNumericsTests {
    private let chain: [RefOp] = [
        .exposure(0.4), .contrast(1.2), .saturation(1.3), .temperature(0.2), .vignette(0.4, 0.4),
        .exposure(-0.2), .contrast(0.9), .saturation(0.8), .temperature(-0.1), .exposure(0.1),
    ]

    private func run(_ ops: [RefOp], _ src: [UInt8], _ w: Int, _ h: Int, optimizations: OptimizationOptions) async throws -> (out: [UInt8], metrics: RenderMetrics) {
        let r = try await ImagePipeline(operations: ops.map(\.operation))
            .renderWithMetrics(makeImage(width: w, height: h, bytes: src), using: try Renderer(optimizations: optimizations))
        return (try pixels(of: r.image), r.metrics)
    }

    @Test("The chain kernel with one operation is bit-identical to that operation's own kernel",
          arguments: [RefOp.exposure(0.7), .exposure(-3), .contrast(1.4), .contrast(0), .saturation(1.6), .saturation(0),
                      .temperature(0.8), .temperature(-1), .vignette(0.9, 0.2), .vignette(0.3, 0.95)])
    func singleOpEquivalence(op: RefOp) async throws {
        let (w, h) = (53, 31)
        let src = testPixels(width: w, height: h)
        let renderer = try Renderer(optimizations: [])
        let texture = try CGImageInterop.makeTexture(from: makeImage(width: w, height: h, bytes: src), context: renderer.context)
        let desc = TextureDescriptor(width: w, height: h)

        // Standalone kernel, via the operation's own plan.
        let plan = try op.operation.plan(inputSize: ImageSize(width: w, height: h))
        let single = plan.steps[0].pass
        var g1 = RenderGraph(); let i1 = g1.addSource("Input", descriptor: desc)
        g1.setOutput(g1.addPass("single", single, inputs: [i1], output: desc))
        let a = try await renderer.run(g1, sources: [i1: texture]) { CGImageInterop.readPixels(from: $0) }

        // The same operation through the chain kernel.
        var g2 = RenderGraph(); let i2 = g2.addSource("Input", descriptor: desc)
        g2.setOutput(g2.addPass("chain", PointwiseFusion.fusedPass([single.pointwise!]), inputs: [i2], output: desc))
        let b = try await renderer.run(g2, sources: [i2: texture]) { CGImageInterop.readPixels(from: $0) }
        #expect(a == b)
    }

    @Test("A fused chain is closer to the exact result than the same chain run pass by pass",
          arguments: [(1, 1), (7, 5), (67, 41), (256, 129)])
    func fusedIsMoreAccurate(size: (Int, Int)) async throws {
        let (w, h) = size
        let src = testPixels(width: w, height: h)
        let exact = referenceExactChain(src, width: w, height: h, ops: chain)
        let fused = try await run(chain, src, w, h, optimizations: .all)
        let unfused = try await run(chain, src, w, h, optimizations: noFusion)
        #expect(fused.metrics.nodes.count == 1 && unfused.metrics.nodes.count == 10)

        let fusedError = maxError(fused.out, exact), unfusedError = maxError(unfused.out, exact)
        // Fused: one 8-bit rounding total, plus float arithmetic. Unfused: ten roundings.
        #expect(fusedError <= 1, "fused \(fusedError) LSB from exact")
        #expect(fusedError <= unfusedError, "fused \(fusedError) vs unfused \(unfusedError)")
        // And the two stay close to each other: the difference is quantization, not a different result.
        #expect(maxError(fused.out, unfused.out) <= unfusedError + fusedError)
        if w * h > 1000 { #expect(unfusedError >= 3, "ten 8-bit roundings should be visible (got \(unfusedError)); if not, this test proves nothing") }
    }

    @Test("Operation order is preserved by fusion")
    func orderMatters() async throws {
        let src = testPixels(width: 64, height: 40)
        let a: [RefOp] = [.exposure(1), .contrast(1.8), .saturation(1.5)]
        let b: [RefOp] = [.saturation(1.5), .contrast(1.8), .exposure(1)]
        let ra = try await run(a, src, 64, 40, optimizations: .all), rb = try await run(b, src, 64, 40, optimizations: .all)
        #expect(maxError(ra.out, referenceExactChain(src, width: 64, height: 40, ops: a)) <= 1)
        #expect(maxError(rb.out, referenceExactChain(src, width: 64, height: 40, ops: b)) <= 1)
        #expect(maxError(ra.out, rb.out) > 8, "reversed chains must differ")
    }

    @Test("A 40-operation chain (two segments of 32 + 8) stays within 2 LSB of exact")
    func longChain() async throws {
        let src = testPixels(width: 61, height: 37)
        var ops: [RefOp] = []
        // Alternating signs keep values mid-range; none are neutral (neutral ops would be eliminated first).
        for i in 0..<10 { ops += [.exposure(i % 2 == 0 ? 0.04 : -0.04), .contrast(1.02), .saturation(0.99), .temperature(i % 2 == 0 ? 0.02 : -0.02)] }
        let r = try await run(ops, src, 61, 37, optimizations: .all)
        #expect(r.metrics.nodes.count == 2 && r.metrics.eliminatedPasses == 38)
        #expect(maxError(r.out, referenceExactChain(src, width: 61, height: 37, ops: ops)) <= 2)
    }

    @Test("Transparent and partly transparent pixels stay valid premultiplied color")
    func alphaSafety() async throws {
        let (w, h) = (80, 50)
        let src = testPixels(width: w, height: h)
        let out = try await run(chain, src, w, h, optimizations: .all).out
        for i in stride(from: 0, to: out.count, by: 4) {
            #expect(out[i + 3] == src[i + 3])
            #expect(out[i] <= out[i + 3] && out[i + 1] <= out[i + 3] && out[i + 2] <= out[i + 3])
            if src[i + 3] == 0 { #expect(out[i] == 0 && out[i + 1] == 0 && out[i + 2] == 0) }
        }
    }

    @Test("A ten-operation pipeline runs as one pass using two textures and one pipeline")
    func resources() async throws {
        let src = testPixels(width: 64, height: 48)
        let renderer = try Renderer()
        let r = try await ImagePipeline(operations: chain.map(\.operation))
            .renderWithMetrics(makeImage(width: 64, height: 48, bytes: src), using: renderer)
        let m = r.metrics
        #expect(m.nodes.count == 1 && m.nodes[0].name == "Fused ×10 (Exposure…Exposure)")
        #expect(m.eliminatedPasses == 9)
        #expect(m.peakActiveTextures == 2 && m.logicalTextures == 2 && m.textureAllocations == 2)
        #expect(m.pipelineCacheMisses == 1 && renderer.statistics.cachedPipelines == 1)
    }

    @Test("Neutral stages are removed before fusion, so they don't split a chain")
    func neutralInsideChain() async throws {
        let src = testPixels(width: 30, height: 20)
        let r = try await ImagePipeline { Exposure(0.3); Contrast(1); Saturation(1.2) }
            .renderWithMetrics(makeImage(width: 30, height: 20, bytes: src), using: try Renderer()).metrics
        #expect(r.nodes.count == 1 && r.nodes[0].name == "Exposure+Saturation" && r.eliminatedPasses == 2)
    }

    @Test("Fusion composes with spatial operations: runs fuse on each side of a blur")
    func aroundBlur() async throws {
        let src = testPixels(width: 90, height: 60)
        let pipeline = ImagePipeline { Exposure(0.3); Contrast(1.1); GaussianBlur(radius: 3); Saturation(1.2); Vignette(amount: 0.3) }
        let on = try await pipeline.renderWithMetrics(makeImage(width: 90, height: 60, bytes: src), using: try Renderer())
        let off = try await pipeline.renderWithMetrics(makeImage(width: 90, height: 60, bytes: src), using: try Renderer(optimizations: noFusion))
        #expect(on.metrics.nodes.map(\.name) == ["Exposure+Contrast", "GaussianBlur horizontal", "GaussianBlur vertical", "Saturation+Vignette"])
        #expect(off.metrics.nodes.count == 6)
        #expect(maxError(try pixels(of: on.image), try pixels(of: off.image)) <= 3)
    }
}
