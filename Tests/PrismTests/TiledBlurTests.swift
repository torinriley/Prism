// TiledBlurTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("Tiled blur: configuration")
struct TiledBlurConfigurationTests {
    @Test("Every radius gets a tile that fits the memory and thread limits", arguments: [1, 2, 7, 24, 48, 64, 96, 128, 191, 192])
    func fits(radius: Int) throws {
        for maxThreads in [1024, 512, 256] {
            for tiling in [BlurTiling.horizontal(radius: radius), .vertical(radius: radius)] {
                let c = try #require(tiling.configuration(maxThreads: maxThreads), "\(tiling) @ \(maxThreads)")
                #expect(c.width >= 1 && c.height >= 1)
                #expect(c.width * c.height <= maxThreads)
                #expect(c.memoryBytes <= 32 * 1024)
                // The tile must hold exactly the elements the kernel will index.
                let n = BlurTiling.outputsPerThread
                switch tiling {
                case .horizontal: #expect(c.memoryBytes == c.height * (c.width * n + 2 * radius) * 16)
                case .vertical: #expect(c.memoryBytes == c.width * (c.height * n + 2 * radius) * 16)
                }
            }
        }
    }

    @Test("A GPU that cannot run a tile is reported, not mis-sized")
    func impossible() {
        #expect(BlurTiling.horizontal(radius: 24).configuration(maxThreads: 8) == nil)
        #expect(BlurTiling.vertical(radius: 24).configuration(maxThreads: 8) == nil)
        #expect(BlurTiling.vertical(radius: 5000).configuration(maxThreads: 1024) == nil, "tile larger than threadgroup memory")
    }

    @Test("The grid has one thread per four pixels along the blur axis, rounded up")
    func grid() {
        #expect(BlurTiling.horizontal(radius: 3).gridSize(width: 4, height: 7) == (1, 7))
        #expect(BlurTiling.horizontal(radius: 3).gridSize(width: 5, height: 7) == (2, 7))
        #expect(BlurTiling.vertical(radius: 3).gridSize(width: 9, height: 1) == (9, 1))
        #expect(BlurTiling.vertical(radius: 3).gridSize(width: 9, height: 13) == (9, 4))
    }

    @Test("Blur plans use the tiled kernels, with padded weights, at every radius")
    func plans() throws {
        for sigma: Float in [0.1, 1, 8, 21.4, 22, 64] {
            let steps = try GaussianBlur(radius: sigma).plan(inputSize: .init(width: 10, height: 10)).steps
            let r = gaussianKernel(sigma: sigma).radius
            #expect(steps.map(\.pass.kernel) == ["prism_blur_horizontal_tiled", "prism_blur_vertical_tiled"])
            #expect(steps[0].pass.tiling == .horizontal(radius: r) && steps[1].pass.tiling == .vertical(radius: r))
            #expect(steps[0].pass.constants.count == (2 * r + 7) * 4, "σ=\(sigma)")
        }
    }
}

@Suite("Tiled blur: GPU", .enabled(if: hasMetal))
struct TiledBlurGPUTests {
    /// A graph running the *direct* (untiled) kernels: the oracle for the tiled ones.
    private func directGraph(sigma: Float, size: TextureDescriptor) -> (RenderGraph, NodeID) {
        struct Params { var radius: Int32 }
        let (radius, weights) = gaussianKernel(sigma: sigma)
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: size)
        let h = g.addPass("H", ComputePass(kernel: "prism_blur_horizontal", uniforms: Params(radius: Int32(radius)), constants: weights), inputs: [input], output: size)
        g.setOutput(g.addPass("V", ComputePass(kernel: "prism_blur_vertical", uniforms: Params(radius: Int32(radius)), constants: weights), inputs: [h], output: size))
        return (g, input)
    }

    @Test("Tiled output is identical to the direct kernels across sizes and radii",
          arguments: [(1, 1), (3, 5), (4, 4), (5, 9), (31, 17), (32, 32), (33, 33), (127, 129), (130, 4), (4, 130), (500, 7), (7, 500), (640, 480)],
          [0.3, 1.0, 4.0, 16.0, 21.4, 22.0, 64.0])
    func matchesDirect(size: (Int, Int), sigma: Double) async throws {
        let (w, h) = size
        let renderer = try Renderer(optimizations: [])
        let desc = TextureDescriptor(width: w, height: h)
        let texture = try CGImageInterop.makeTexture(from: makeImage(width: w, height: h, bytes: testPixels(width: w, height: h)), context: renderer.context)

        let (direct, source) = directGraph(sigma: Float(sigma), size: desc)
        let expected = try await renderer.run(direct, sources: [source: texture]) { CGImageInterop.readPixels(from: $0) }

        let (tiledGraph, tiledSource) = try RenderGraph.chain([GaussianBlur(radius: Float(sigma))], source: desc)
        let actual = try await renderer.run(tiledGraph, sources: [tiledSource: texture]) { CGImageInterop.readPixels(from: $0) }
        #expect(actual == expected, "\(w)×\(h) σ=\(sigma): max difference \(maxError(actual, expected)) LSB")
    }

    @Test("Tiled blur matches the Double-precision reference at large radii",
          arguments: [(37, 29, 24.0), (200, 3, 40.0), (3, 200, 40.0), (64, 64, 64.0)])
    func matchesReference(w: Int, h: Int, sigma: Double) async throws {
        let src = testPixels(width: w, height: h)
        let out = try await ImagePipeline { GaussianBlur(radius: Float(sigma)) }.render(makeImage(width: w, height: h, bytes: src))
        #expect(maxError(try pixels(of: out), referenceBlur(src, width: w, height: h, sigma: Float(sigma))) <= 1)
    }

    @Test("A tile wider than the image (halo larger than the picture) is handled by edge clamping")
    func haloLargerThanImage() async throws {
        let src = testPixels(width: 2, height: 2)
        let out = try await ImagePipeline { GaussianBlur(radius: 64) }.render(makeImage(width: 2, height: 2, bytes: src))
        #expect(maxError(try pixels(of: out), referenceBlur(src, width: 2, height: 2, sigma: 64)) <= 1)
    }

    @Test("Blur chains and Sharpen still work on the tiled path (fused neighbours, branch)")
    func composition() async throws {
        let (w, h) = (97, 61)
        let src = testPixels(width: w, height: h)
        let p = ImagePipeline { Exposure(0.2); GaussianBlur(radius: 5); Sharpen(amount: 0.8, radius: 3); Contrast(1.1) }
        let fused = try pixels(of: try await p.render(makeImage(width: w, height: h, bytes: src), using: try Renderer()))
        let plain = try pixels(of: try await p.render(makeImage(width: w, height: h, bytes: src), using: try Renderer(optimizations: [])))
        #expect(maxError(fused, plain) <= 3)
    }

    @Test("Concurrent tiled blurs of different sizes and radii are all correct")
    func concurrency() async throws {
        let renderer = try Renderer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let (w, h) = [(50, 30), (31, 99), (128, 16)][i % 3]
                    let sigma = Float([1, 5, 20, 40][i % 4])
                    let src = testPixels(width: w, height: h)
                    let out = try await ImagePipeline { GaussianBlur(radius: sigma) }.render(makeImage(width: w, height: h, bytes: src), using: renderer)
                    #expect(maxError(try pixels(of: out), referenceBlur(src, width: w, height: h, sigma: sigma)) <= 1)
                }
            }
            try await group.waitForAll()
        }
        #expect(renderer.statistics.activeTextures == 0)
    }
}
