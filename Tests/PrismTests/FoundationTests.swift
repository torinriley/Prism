// FoundationTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("Foundation", .enabled(if: hasMetal))
struct FoundationTests {
    @Test("Context loads the shader library and builds a pipeline")
    func contextAndPipeline() throws {
        let ctx = try MetalContext()
        let pipeline = try ctx.makePipeline(kernel: "prism_invert")
        #expect(pipeline.maxTotalThreadsPerThreadgroup > 0)
        #expect(throws: PrismError.shaderFunctionNotFound(name: "nope")) {
            try ctx.makePipeline(kernel: "nope")
        }
    }

    @Test("CGImage → texture preserves bytes exactly", arguments: [(1, 1), (2, 3), (17, 5), (64, 64), (257, 129)])
    func uploadIsExact(size: (Int, Int)) throws {
        let ctx = try MetalContext()
        let src = testPixels(width: size.0, height: size.1)
        let texture = try CGImageInterop.makeTexture(
            from: makeImage(width: size.0, height: size.1, bytes: src), context: ctx)
        #expect(texture.width == size.0 && texture.height == size.1)
        #expect(CGImageInterop.readPixels(from: texture) == src)
    }

    @Test("Texture → CGImage → texture round trip is exact")
    func exportRoundTrip() throws {
        let ctx = try MetalContext()
        let src = testPixels(width: 33, height: 21)
        let t1 = try CGImageInterop.makeTexture(from: makeImage(width: 33, height: 21, bytes: src), context: ctx)
        let t2 = try CGImageInterop.makeTexture(from: CGImageInterop.makeCGImage(from: t1), context: ctx)
        #expect(CGImageInterop.readPixels(from: t2) == src)
    }

    @Test("Invert kernel matches CPU reference, including transparent and odd-sized images",
          arguments: [(1, 1), (3, 7), (129, 65), (1000, 3)])
    func invertMatchesReference(size: (Int, Int)) async throws {
        let ctx = try MetalContext()
        let src = testPixels(width: size.0, height: size.1)
        let input = try CGImageInterop.makeTexture(
            from: makeImage(width: size.0, height: size.1, bytes: src), context: ctx)
        let output = try ctx.makeTexture(width: size.0, height: size.1)
        let pipeline = try ctx.makePipeline(kernel: "prism_invert")

        let cb = try #require(ctx.queue.makeCommandBuffer())
        let enc = try #require(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setTexture(input, index: 0)
        enc.setTexture(output, index: 1)
        enc.dispatch(pipeline, width: size.0, height: size.1)
        enc.endEncoding()
        try await cb.commitAndWait()

        let got = CGImageInterop.readPixels(from: output)
        var maxError = 0
        for i in stride(from: 0, to: src.count, by: 4) {
            let a = Int(src[i + 3])
            for c in 0..<3 { maxError = max(maxError, abs(Int(got[i + c]) - (a - Int(src[i + c])))) }
            #expect(got[i + 3] == src[i + 3])
        }
        // a - c is exact in float; unorm8 round-trips are exact up to 1 LSB of conversion.
        #expect(maxError <= 1, "max error \(maxError) LSB")
    }
}
