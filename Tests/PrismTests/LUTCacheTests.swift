// LUTCacheTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("LUT texture cache", .enabled(if: hasMetal))
struct LUTCacheTests {
    private func curved(_ n: Int, shift: Float = 0) throws -> LUT3D {
        var v: [Float] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let (x, y, z) = (Float(r) / Float(n - 1), Float(g) / Float(n - 1), Float(b) / Float(n - 1))
            v += [min(1, 1 - z + shift), x * y, y * y]
        } } }
        return try LUT3D(size: n, rgb: v)
    }
    private let src = testPixels(width: 40, height: 24)
    private var image: CGImage { makeImage(width: 40, height: 24, bytes: src) }

    @Test("A LUT is uploaded once and reused across renders")
    func reuse() async throws {
        let renderer = try Renderer()
        let lut = try curved(17)
        let p = ImagePipeline { LUTGrade(lut) }
        var first: [UInt8] = []
        for i in 0..<6 {
            let out = try pixels(of: try await p.render(image, using: renderer))
            if i == 0 { first = out } else { #expect(out == first) }
        }
        let s = renderer.statistics
        #expect(s.lutTextureUploads == 1 && s.lutTextureHits == 5)
        #expect(s.cachedLUTBytes >= 17 * 17 * 17 * 16)
    }

    @Test("Two passes with one LUT share a texture; copies of a LUT share its identity")
    func sharing() async throws {
        let renderer = try Renderer()
        let lut = try curved(9)
        let copy = lut
        _ = try await ImagePipeline { LUTGrade(lut, intensity: 0.5); Contrast(1.2); LUTGrade(copy) }.render(image, using: renderer)
        #expect(renderer.statistics.lutTextureUploads == 1 && renderer.statistics.lutTextureHits == 1)
    }

    @Test("Different LUTs stay different, even with the same size and shape")
    func distinct() async throws {
        let renderer = try Renderer()
        let a = try curved(9), b = try curved(9, shift: -0.4)
        let outA = try pixels(of: try await ImagePipeline { LUTGrade(a) }.render(image, using: renderer))
        let outB = try pixels(of: try await ImagePipeline { LUTGrade(b) }.render(image, using: renderer))
        #expect(outA != outB, "a cache keyed on size alone would return A's texture for B")
        #expect(renderer.statistics.lutTextureUploads == 2)
        // And each still gives its own result when cached. On a mismatch, say how large it is and whether it
        // persists (a wrong cached texture) or was a one-off (a nondeterministic render).
        for (name, lut, expected) in [("A", a, outA), ("B", b, outB)] {
            let again = try pixels(of: try await ImagePipeline { LUTGrade(lut) }.render(image, using: renderer))
            if again != expected {
                let third = try pixels(of: try await ImagePipeline { LUTGrade(lut) }.render(image, using: renderer))
                let differing = zip(again, expected).filter { $0 != $1 }.count
                Issue.record("LUT \(name) re-render differs: \(differing) of \(again.count) bytes, max \(maxError(again, expected)) LSB; a third render \(third == expected ? "matches the original" : third == again ? "matches the second (stable but different)" : "differs from both (nondeterministic)")")
            }
        }
        #expect(renderer.statistics.lutTextureUploads == 2)
    }

    @Test("Least recently used LUTs are evicted once the budget is exceeded")
    func eviction() throws {
        let ctx = try MetalContext()
        let probe = try ctx.makeLUTTexture(try curved(9))
        let cache = LUTTextureCache(context: ctx, budgetBytes: probe.allocatedSize * 5 / 2)   // room for two
        let a = try curved(9), b = try curved(9), c = try curved(9)
        _ = try cache.texture(for: a); _ = try cache.texture(for: b); _ = try cache.texture(for: c)
        #expect(cache.statistics == .init(uploads: 3, hits: 0, cachedLUTs: 2, cachedBytes: probe.allocatedSize * 2))
        _ = try cache.texture(for: b)                       // hit; b is now the most recent
        #expect(cache.statistics.hits == 1)
        _ = try cache.texture(for: a)                       // evicted earlier: re-upload, and c (oldest) goes
        #expect(cache.statistics.uploads == 4 && cache.statistics.cachedLUTs == 2)
        _ = try cache.texture(for: b)                       // survived
        #expect(cache.statistics.hits == 2)
        _ = try cache.texture(for: c)                       // was evicted
        #expect(cache.statistics.uploads == 5)
    }

    @Test("A LUT larger than the whole budget is used but not kept")
    func tooBigToKeep() throws {
        let ctx = try MetalContext()
        let cache = LUTTextureCache(context: ctx, budgetBytes: 1024)
        let lut = try curved(9)
        for _ in 0..<3 { _ = try cache.texture(for: lut) }
        #expect(cache.statistics == .init(uploads: 3, hits: 0, cachedLUTs: 0, cachedBytes: 0))
    }

    @Test("Concurrent renders of one LUT upload it exactly once")
    func contention() async throws {
        let renderer = try Renderer()
        let lut = try curved(17)
        let expected = try pixels(of: try await ImagePipeline { LUTGrade(lut) }.render(image, using: Renderer()))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let out = try await ImagePipeline { LUTGrade(lut) }.render(makeImage(width: 40, height: 24, bytes: testPixels(width: 40, height: 24)), using: renderer)
                    #expect(try pixels(of: out) == expected)
                }
            }
            try await group.waitForAll()
        }
        #expect(renderer.statistics.lutTextureUploads == 1 && renderer.statistics.lutTextureHits == 31)
    }

    @Test("purgeTexturePool drops cached LUTs, and purging during renders is safe")
    func purging() async throws {
        let renderer = try Renderer()
        let lut = try curved(17)
        let p = ImagePipeline { LUTGrade(lut) }
        let expected = try pixels(of: try await p.render(image, using: renderer))
        renderer.purgeTexturePool()
        #expect(renderer.statistics.cachedLUTBytes == 0)
        _ = try await p.render(image, using: renderer)
        #expect(renderer.statistics.lutTextureUploads == 2)

        // Textures evicted while a command buffer still uses them must stay valid until it finishes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let out = try await p.render(makeImage(width: 40, height: 24, bytes: testPixels(width: 40, height: 24)), using: renderer)
                    #expect(try pixels(of: out) == expected)
                }
                group.addTask { for _ in 0..<20 { renderer.purgeTexturePool(); await Task.yield() } }
            }
            try await group.waitForAll()
        }
    }

    @Test("The texture path uses the same cache")
    func texturePath() async throws {
        let renderer = try Renderer()
        let lut = try curved(9)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 40, height: 24, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        let input = try #require(renderer.context.device.makeTexture(descriptor: desc))
        input.replace(region: MTLRegionMake2D(0, 0, 40, 24), mipmapLevel: 0, withBytes: src, bytesPerRow: 160)
        for _ in 0..<3 { _ = try await ImagePipeline { LUTGrade(lut) }.render(input, using: renderer) }
        #expect(renderer.statistics.lutTextureUploads == 1 && renderer.statistics.lutTextureHits == 2)
    }
}
