// PipelineTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Testing
@testable import Prism

@Suite("Pipeline", .enabled(if: hasMetal))
struct PipelineTests {
    static let size = (w: 67, h: 41)   // odd on purpose
    let src = testPixels(width: size.w, height: size.h)
    var image: CGImage { makeImage(width: Self.size.w, height: Self.size.h, bytes: src) }

    @Test("Empty pipeline returns the input unchanged")
    func emptyPipeline() async throws {
        let out = try await ImagePipeline {}.render(image)
        #expect(try pixels(of: out) == src)
    }

    @Test("Identity parameters are exact no-ops in 8-bit")
    func identities() async throws {
        let out = try await ImagePipeline { Exposure(0); Contrast(1) }.render(image)
        // Float round trip through sRGB decode/encode must land back on the same 8-bit value.
        #expect(maxError(try pixels(of: out), src) == 0)
    }

    @Test("Exposure matches the CPU reference", arguments: [-3.0, -0.5, 0.4, 2.0, 10.0])
    func exposure(stops: Double) async throws {
        let out = try await ImagePipeline { Exposure(Float(stops)) }.render(image)
        let err = maxError(try pixels(of: out), referenceExposure(src, stops: stops))
        #expect(err <= 1, "max error \(err) LSB at \(stops) EV")
    }

    @Test("Contrast matches the CPU reference", arguments: [0.0, 0.5, 1.15, 4.0])
    func contrast(factor: Double) async throws {
        let out = try await ImagePipeline { Contrast(Float(factor)) }.render(image)
        let err = maxError(try pixels(of: out), referenceContrast(src, factor: factor))
        #expect(err <= 1, "max error \(err) LSB at factor \(factor)")
    }

    @Test("Sequential operations compose, and the order matters")
    func composition() async throws {
        let a = try await ImagePipeline { Exposure(0.5); Contrast(1.3) }.render(image)
        let b = try await ImagePipeline { Contrast(1.3); Exposure(0.5) }.render(image)
        let ref = referenceContrast(referenceExposure(src, stops: 0.5), factor: 1.3)
        // Two 8-bit rounding steps in the reference vs. one float chain on the GPU.
        #expect(maxError(try pixels(of: a), ref) <= 2)
        #expect(maxError(try pixels(of: a), try pixels(of: b)) > 2)
    }

    @Test("Builder supports conditionals and loops")
    func builder() async throws {
        let on = true
        let p = ImagePipeline {
            if on { Exposure(0.1) }
            for _ in 0..<3 { Contrast(1.01) }
        }
        #expect(p.operations.count == 4)
    }

    @Test("Invalid parameters throw before any GPU work", arguments: [Float.nan, .infinity, 11, -11])
    func invalidExposure(stops: Float) async throws {
        await #expect(throws: PrismError.self) { try await ImagePipeline { Exposure(stops) }.render(image) }
    }

    @Test("Transparent pixels stay transparent")
    func transparency() async throws {
        let clear = makeImage(width: 4, height: 4, bytes: [UInt8](repeating: 0, count: 64))
        let out = try await ImagePipeline { Exposure(3); Contrast(2) }.render(clear)
        #expect(try pixels(of: out) == [UInt8](repeating: 0, count: 64))
    }

    // MARK: Cache

    @Test("Pipeline states compile once and are reused across renders")
    func cacheReuse() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        let p = ImagePipeline { Exposure(0.2); Contrast(1.1); Exposure(0.1) }
        _ = try await p.render(image, using: renderer)
        let cold = renderer.pipelineCache.statistics
        #expect(cold == .init(hits: 1, misses: 2, cachedPipelines: 2))
        _ = try await p.render(image, using: renderer)
        let warm = renderer.pipelineCache.statistics
        #expect(warm == .init(hits: 4, misses: 2, cachedPipelines: 2))
    }

    @Test("Concurrent requests for one kernel compile it exactly once")
    func cacheContention() async throws {
        let renderer = try Renderer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { _ = try renderer.pipelineCache.pipeline(kernel: "prism_exposure") }
            }
            try await group.waitForAll()
        }
        #expect(renderer.pipelineCache.statistics == .init(hits: 63, misses: 1, cachedPipelines: 1))
    }

    // MARK: Concurrency

    @Test("Simultaneous renders of different sizes and pipelines are all correct")
    func concurrentRenders() async throws {
        let renderer = try Renderer()
        let sizes = [(1, 1), (7, 3), (64, 64), (130, 17), (333, 211)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for round in 0..<4 {
                for (w, h) in sizes {
                    group.addTask {
                        let bytes = testPixels(width: w, height: h)
                        let stops = Float(round) * 0.5 - 0.5
                        let out = try await ImagePipeline { Exposure(stops); Contrast(1) }
                            .render(makeImage(width: w, height: h, bytes: bytes), using: renderer)
                        let err = maxError(try pixels(of: out), referenceExposure(bytes, stops: Double(stops)))
                        #expect(err <= 1, "\(w)×\(h) round \(round): \(err) LSB")
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("A pipeline value is reusable across many renders")
    func pipelineReuse() async throws {
        let p = ImagePipeline { Exposure(0.3) }
        let first = try pixels(of: try await p.render(image))
        for _ in 0..<10 { #expect(try pixels(of: try await p.render(image)) == first) }
    }

    @Test("Cancelling before submission throws CancellationError")
    func cancellation() async throws {
        let img = image
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await ImagePipeline { Exposure(1) }.render(img)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
