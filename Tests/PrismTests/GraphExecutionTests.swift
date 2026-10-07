// GraphExecutionTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("Graph execution", .enabled(if: hasMetal))
struct GraphExecutionTests {
    /// Input → Exposure ─┬→ Contrast ─┐
    ///                   └→ Exposure ─┴→ Mix(0.5) → Output
    @Test func diamondMatchesReference() async throws {
        let (w, h) = (53, 29)
        let src = testPixels(width: w, height: h)
        let renderer = try Renderer()
        let d = TextureDescriptor(width: w, height: h)

        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let base = g.addPass("Exposure", try Exposure(0.5).plan(inputSize: .init(width: w, height: h)).steps[0].pass, inputs: [input], output: d)
        let left = g.addPass("Contrast", try Contrast(1.4).plan(inputSize: .init(width: w, height: h)).steps[0].pass, inputs: [base], output: d)
        let right = g.addPass("Exposure", try Exposure(-1).plan(inputSize: .init(width: w, height: h)).steps[0].pass, inputs: [base], output: d)
        struct Mix { var t: Float }
        let merged = g.addPass("Mix", ComputePass(kernel: "prism_mix", uniforms: Mix(t: 0.5)), inputs: [left, right], output: d)
        g.setOutput(merged)

        let texture = try CGImageInterop.makeTexture(
            from: makeImage(width: w, height: h, bytes: src), context: renderer.context)
        let out = try await renderer.run(g, sources: [input: texture]) { CGImageInterop.readPixels(from: $0) }

        let b = referenceExposure(src, stops: 0.5)
        let l = referenceContrast(b, factor: 1.4), r = referenceExposure(b, stops: -1)
        let expected = zip(l, r).map { UInt8((Double($0) + Double($1)) / 2 + 0.5) }
        let err = maxError(out, expected)
        #expect(err <= 3, "max error \(err) LSB")
    }

    @Test func nodeOrderInGraphDoesNotChangeResult() async throws {
        // Same computation, nodes declared in a different (but valid) order.
        let (w, h) = (16, 16)
        let src = testPixels(width: w, height: h)
        let renderer = try Renderer()
        let d = TextureDescriptor(width: w, height: h)
        let inv = ComputePass(kernel: "prism_invert")
        let nodes: [RenderGraph.Node] = [
            .init(id: .init(rawValue: 0), name: "Input", work: .source, inputs: [], output: d),
            .init(id: .init(rawValue: 1), name: "Second", work: .compute(inv), inputs: [.init(rawValue: 2)], output: d),
            .init(id: .init(rawValue: 2), name: "First", work: .compute(inv), inputs: [.init(rawValue: 0)], output: d),
        ]
        let g = RenderGraph(nodes: nodes, output: .init(rawValue: 1))
        let texture = try CGImageInterop.makeTexture(from: makeImage(width: w, height: h, bytes: src), context: renderer.context)
        let out = try await renderer.run(g, sources: [.init(rawValue: 0): texture]) { CGImageInterop.readPixels(from: $0) }
        // Invert twice = identity (within unorm rounding).
        #expect(maxError(out, src) <= 1)
    }

    @Test func missingSourceTextureThrows() async throws {
        let renderer = try Renderer()
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: .init(width: 4, height: 4))
        g.setOutput(g.addPass("Inv", ComputePass(kernel: "prism_invert"), inputs: [input], output: .init(width: 4, height: 4)))
        await #expect(throws: PrismError.self) { _ = try await renderer.run(g, sources: [:]) { _ in () } }
    }

    @Test func wrongSizedSourceTextureThrows() async throws {
        let renderer = try Renderer()
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: .init(width: 4, height: 4))
        g.setOutput(input)
        let wrong = try renderer.context.makeTexture(width: 5, height: 4)
        await #expect(throws: PrismError.self) { _ = try await renderer.run(g, sources: [input: wrong]) { _ in () } }
    }

    @Test func invalidGraphIsRejectedBeforeEncoding() async throws {
        let renderer = try Renderer()
        let g = RenderGraph(nodes: [], output: nil)
        await #expect(throws: PrismError.self) { _ = try await renderer.run(g, sources: [:]) { _ in () } }
    }
}
