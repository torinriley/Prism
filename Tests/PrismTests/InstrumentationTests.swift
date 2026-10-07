// InstrumentationTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Testing
@testable import Prism

@Suite("Instrumentation", .enabled(if: hasMetal))
struct InstrumentationTests {
    private func image(_ w: Int, _ h: Int) -> CGImage { makeImage(width: w, height: h, bytes: testPixels(width: w, height: h)) }
    private let pipeline = ImagePipeline { Exposure(0.3); Contrast(1.1); Exposure(-0.1) }

    @Test("Standard metrics describe the render and its time breakdown")
    func standard() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        let m = try await pipeline.renderWithMetrics(image(300, 200), using: renderer).metrics
        #expect(m.level == .standard)
        #expect(m.inputSize == ImageSize(width: 300, height: 200) && m.outputSize == m.inputSize)
        let parts = [m.importDuration, m.cpuEncodeDuration, m.gpuDuration, m.exportDuration].compactMap { $0 }
        #expect(parts.count == 4 && parts.allSatisfy { $0 > 0 })
        #expect(m.totalDuration >= m.importDuration! + m.cpuEncodeDuration! + m.exportDuration!)
        #expect(m.totalDuration >= m.gpuDuration!, "wall time covers the GPU's execution")
        #expect(m.nodes.map(\.name) == ["Exposure", "Contrast", "Exposure"])
        #expect(m.nodes.allSatisfy { $0.gpuDuration == nil && $0.outputSize == m.inputSize }, "per-node timing is opt-in")
    }

    @Test("Resource and cache counters are exact, cold then warm")
    func counters() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        let cold = try await pipeline.renderWithMetrics(image(64, 64), using: renderer).metrics
        // 3 passes → 2 recycled slots + the input = 3 textures live; 4 logical (input + 3 outputs).
        #expect(cold.peakActiveTextures == 3 && cold.logicalTextures == 4)
        #expect(cold.textureAllocations == 3 && cold.textureReuses == 0)
        #expect(cold.pipelineCacheMisses == 2 && cold.pipelineCacheHits == 1, "Exposure, Contrast compile once; second Exposure hits")
        #expect(cold.peakTextureBytes >= 3 * 64 * 64 * 4)

        let warm = try await pipeline.renderWithMetrics(image(64, 64), using: renderer).metrics
        #expect(warm.textureAllocations == 0 && warm.textureReuses == 3)
        #expect(warm.pipelineCacheMisses == 0 && warm.pipelineCacheHits == 3)
    }

    @Test("Off keeps counters and wall time but drops timing breakdown")
    func off() async throws {
        let renderer = try Renderer(instrumentation: .off, optimizations: noFusion)
        let m = try await pipeline.renderWithMetrics(image(64, 64), using: renderer).metrics
        #expect(m.level == .off && m.totalDuration > 0)
        #expect(m.importDuration == nil && m.cpuEncodeDuration == nil && m.gpuDuration == nil && m.exportDuration == nil)
        #expect(m.nodes.count == 3 && m.textureAllocations == 3 && m.pipelineCacheMisses == 2)
    }

    @Test("Instrumentation level never changes pixels")
    func levelsAgree() async throws {
        let src = image(131, 77)
        let ops = ImagePipeline { Exposure(0.4); GaussianBlur(radius: 3); Sharpen(amount: 0.6); Vignette(amount: 0.4); Resize(scale: 0.7) }
        var outputs: [[UInt8]] = []
        for level in [InstrumentationLevel.off, .standard, .detailed] {
            outputs.append(try pixels(of: try await ops.render(src, using: try Renderer(instrumentation: level))))
        }
        #expect(outputs[0] == outputs[1] && outputs[1] == outputs[2])
    }

    @Test("Detailed mode times every pass, consistently with the command buffer")
    func detailed() async throws {
        let renderer = try Renderer(instrumentation: .detailed)
        let big = image(2048, 1536)
        let p = ImagePipeline { Exposure(0.2); GaussianBlur(radius: 12); Vignette(amount: 0.3) }
        _ = try await p.renderWithMetrics(big, using: renderer)          // warm up
        let m = try await p.renderWithMetrics(big, using: renderer).metrics
        let times = m.nodes.map(\.gpuDuration)
        try #require(times.allSatisfy { $0 != nil }, "this GPU should support timestamp counters")
        #expect(m.nodes.map(\.name) == ["Exposure", "GaussianBlur horizontal", "GaussianBlur vertical", "Vignette"])
        let sum = times.compactMap { $0 }.reduce(0, +)
        #expect(times.allSatisfy { $0! > 0 })
        // Passes are timed independently of the buffer interval, so they must fit inside it
        // (small tolerance for clock-rate calibration error).
        #expect(sum <= m.gpuDuration! * 1.05, "passes \(sum * 1000) ms vs buffer \(m.gpuDuration! * 1000) ms")
        #expect(sum >= m.gpuDuration! * 0.5, "passes account for most of the GPU time")
        // A σ=12 blur pass should cost clearly more than a per-pixel pass. This is a relationship
        // between timings, so it is checked on medians of several renders with a loose factor. The
        // reference is the cheaper of the two per-pixel passes because the first pass in a command
        // buffer absorbs a start-up cost (an idle GPU wakes up), which can make it look expensive.
        var perPass: [[Double]] = [[], [], [], []]
        for _ in 0..<7 {
            let sample = try await p.renderWithMetrics(big, using: renderer).metrics.nodes.map { $0.gpuDuration! }
            for (i, t) in sample.enumerated() { perPass[i].append(t) }
        }
        let median = { (xs: [Double]) in xs.sorted()[xs.count / 2] }
        let perPixel = min(median(perPass[0]), median(perPass[3]))
        #expect(median(perPass[1]) > perPixel * 1.5 && median(perPass[2]) > perPixel * 1.5,
                "median pass times (ms): \(perPass.map { median($0) * 1000 })")
    }

    @Test("Per-render counters add up to the renderer's lifetime statistics, even under concurrency")
    func conservation() async throws {
        let renderer = try Renderer()
        let sizes = [(32, 32), (48, 24), (32, 32), (100, 60)]
        let metrics = try await withThrowingTaskGroup(of: RenderMetrics.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let (w, h) = sizes[i % sizes.count]
                    let p = ImagePipeline { Exposure(0.1); GaussianBlur(radius: 2); Contrast(1.2) }
                    return try await p.renderWithMetrics(makeImage(width: w, height: h, bytes: testPixels(width: w, height: h)), using: renderer).metrics
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let stats = renderer.statistics
        #expect(metrics.map(\.textureAllocations).reduce(0, +) == stats.textureAllocations)
        #expect(metrics.map(\.textureReuses).reduce(0, +) == stats.textureReuses)
        #expect(metrics.map(\.pipelineCacheMisses).reduce(0, +) == stats.pipelineCacheMisses)
        #expect(metrics.map(\.pipelineCacheHits).reduce(0, +) == stats.pipelineCacheHits)
        #expect(stats.pipelineCacheMisses == 4 && stats.cachedPipelines == 4, "exposure, 2 blur kernels, contrast")
        #expect(stats.activeTextures == 0)
    }

    @Test("Renderer statistics mirror the cache and pool")
    func statistics() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        _ = try await pipeline.render(image(40, 40), using: renderer)
        let s = renderer.statistics
        #expect(s.cachedPipelines == 2 && s.pipelineCacheMisses == 2 && s.pipelineCacheHits == 1)
        #expect(s.textureAllocations == 3 && s.pooledTextures == 3 && s.activeTextures == 0)
        #expect(s.residentTextureBytes > 0 && s.peakResidentTextureBytes == s.residentTextureBytes)
        renderer.purgeTexturePool()
        #expect(renderer.statistics.residentTextureBytes == 0)
    }

    @Test("A size-changing pipeline reports per-pass output sizes")
    func sizes() async throws {
        let m = try await ImagePipeline { Resize(width: 50, height: 20); Vignette(amount: 0.5) }
            .renderWithMetrics(image(100, 100), using: try Renderer()).metrics
        #expect(m.outputSize == ImageSize(width: 50, height: 20))
        #expect(m.nodes.map(\.outputSize) == [ImageSize(width: 50, height: 20), ImageSize(width: 50, height: 20)])
    }

    @Test("The description reads like an inspector panel")
    func description() async throws {
        let m = try await pipeline.renderWithMetrics(image(32, 32), using: try Renderer(optimizations: noFusion)).metrics
        let text = m.description
        for fragment in ["FRAME", "GRAPH", "Contrast", "RESOURCES", "PIPELINES", "2 compiled"] {
            #expect(text.contains(fragment), "missing \(fragment) in:\n\(text)")
        }
    }
}
