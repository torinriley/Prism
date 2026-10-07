// TextureAPITests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("Texture input/output", .enabled(if: hasMetal))
struct TextureAPITests {
    let w = 61, h = 37
    var src: [UInt8] { testPixels(width: w, height: h) }

    private func texture(
        _ bytes: [UInt8], format: MTLPixelFormat = .rgba8Unorm, usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
        storage: MTLStorageMode = .shared, width: Int? = nil, height: Int? = nil, device: (any MTLDevice)? = nil
    ) throws -> any MTLTexture {
        let device = try device ?? #require(MTLCreateSystemDefaultDevice())
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width ?? w, height: height ?? h, mipmapped: false)
        desc.usage = usage; desc.storageMode = storage
        let t = try #require(device.makeTexture(descriptor: desc))
        let bytesPerPixel = switch format {
        case .rgba16Float: 8
        case .rgba32Float: 16
        default: 4
        }
        t.replace(
            region: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: t.width * bytesPerPixel)
        return t
    }
    private func bytes(_ t: any MTLTexture) -> [UInt8] { CGImageInterop.readPixels(from: t) }
    /// Swaps the red and blue channels (RGBA ↔ BGRA).
    private func swapRB(_ input: [UInt8]) -> [UInt8] {
        var out = input
        for i in stride(from: 0, to: input.count, by: 4) { out[i] = input[i + 2]; out[i + 2] = input[i] }
        return out
    }
    private let ops = ImagePipeline { Exposure(0.4); Contrast(1.2); GaussianBlur(radius: 2); Saturation(0.8) }

    @Test("A texture render matches the CGImage render exactly")
    func matchesCGImagePath() async throws {
        let renderer = try Renderer()
        let viaImage = try pixels(of: try await ops.render(makeImage(width: w, height: h, bytes: src), using: renderer))
        let out = try await ops.render(try texture(src), using: renderer)
        #expect(bytes(out) == viaImage)
        #expect(out.width == w && out.height == h && out.pixelFormat == .rgba8Unorm)
    }

    @Test("bgra8Unorm input produces the same colors, in bgra")
    func bgra() async throws {
        let renderer = try Renderer()
        let rgba = bytes(try await ops.render(try texture(src), using: renderer))
        let bgraInput = try texture(swapRB(src), format: .bgra8Unorm)
        let out = try await ops.render(bgraInput, using: renderer)
        #expect(out.pixelFormat == .bgra8Unorm)
        #expect(swapRB(bytes(out)) == rgba)
    }

    @Test("A supplied destination is written and returned; reusing it across frames works")
    func destination() async throws {
        let renderer = try Renderer()
        let input = try texture(src)
        let dest = try texture([UInt8](repeating: 0xAB, count: w * h * 4))
        let expected = bytes(try await ops.render(input, using: renderer))
        let out = try await ops.render(input, into: dest, using: renderer)
        #expect(out === dest)
        #expect(bytes(dest) == expected)
        // Reuse for a different pipeline: nothing from the previous frame may leak through.
        let other = ImagePipeline { Vignette(amount: 0.9, radius: 0.1); Temperature(0.5) }
        let again = try await other.render(input, into: dest, using: renderer)
        #expect(again === dest)
        #expect(bytes(dest) == bytes(try await other.render(input, using: renderer)))
        #expect(bytes(input) == src, "the input is never modified")
    }

    @Test("The destination slot also serves earlier passes, without corrupting the result")
    func destinationSharedWithEarlierPasses() async throws {
        // Unfused chain: the output slot is reused from a dead intermediate, so intermediates
        // are written into the caller's texture before the final pass.
        let renderer = try Renderer(optimizations: noFusion)
        var stages: [any ImageOperation] = []
        for i in 0..<6 { stages.append(Exposure(Float(i % 2) * 0.2 - 0.1)); stages.append(Contrast(1.05)) }
        let chain = ImagePipeline(operations: stages)
        let input = try texture(src)
        let dest = try texture(src)
        _ = try await chain.render(input, into: dest, using: renderer)
        #expect(bytes(dest) == bytes(try await chain.render(input, using: renderer)))
    }

    @Test("A size-changing pipeline allocates an output of the new size")
    func resizeAllocates() async throws {
        let out = try await ImagePipeline { Resize(width: 20, height: 11); Vignette(amount: 0.4) }.render(try texture(src), using: try Renderer())
        #expect(out.width == 20 && out.height == 11 && out.pixelFormat == .rgba8Unorm)
        #expect(out.usage.contains(.shaderRead) && out.usage.contains(.shaderWrite))
    }

    @Test("A pipeline that does nothing returns an equal, distinct texture")
    func noOpPipeline() async throws {
        let input = try texture(src)
        let renderer = try Renderer()
        let out = try await ImagePipeline { Exposure(0); Contrast(1) }.render(input, using: renderer)
        #expect(out !== input && bytes(out) == src)
        let dest = try texture([UInt8](repeating: 0, count: w * h * 4))
        _ = try await ImagePipeline { Exposure(0) }.render(input, into: dest, using: renderer)
        #expect(bytes(dest) == src)
    }

    @Test("A GPU-only (private) input texture works")
    func privateInput() async throws {
        let renderer = try Renderer()
        let shared = try texture(src)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead; desc.storageMode = .private
        let privateTexture = try #require(shared.device.makeTexture(descriptor: desc))
        let cb = try #require(renderer.context.queue.makeCommandBuffer()), blit = try #require(cb.makeBlitCommandEncoder())
        blit.copy(from: shared, to: privateTexture); blit.endEncoding()
        try await cb.commitAndWait()
        #expect(bytes(try await ops.render(privateTexture, using: renderer)) == bytes(try await ops.render(shared, using: renderer)))
    }

    @Test("Unusable inputs are rejected with clear errors")
    func invalidInputs() async throws {
        let renderer = try Renderer()
        let p = ImagePipeline { Exposure(0.5) }
        let writeOnly = try texture(src, usage: .shaderWrite)
        let half = try texture([UInt8](repeating: 0, count: w * h * 16), format: .rgba32Float)
        await #expect(throws: PrismError.self, "no shaderRead") { _ = try await p.render(writeOnly, using: renderer) }
        await #expect(throws: PrismError.self, "unsupported format") { _ = try await p.render(half, using: renderer) }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        desc.textureType = .type2DMultisample; desc.sampleCount = 4; desc.storageMode = .private; desc.usage = .shaderRead
        if let ms = renderer.context.device.makeTexture(descriptor: desc) {
            await #expect(throws: PrismError.self, "multisample") { _ = try await p.render(ms, using: renderer) }
        }
        let ok = try texture(src)
        await #expect(throws: PrismError.self, "invalid parameters still throw") {
            _ = try await ImagePipeline { Exposure(.nan) }.render(ok, using: renderer)
        }
    }

    @Test("Unusable destinations are rejected, and the input is left alone")
    func invalidDestinations() async throws {
        let renderer = try Renderer()
        let p = ImagePipeline { Exposure(0.5) }
        let input = try texture(src)
        func rejects(_ label: String, _ dest: any MTLTexture) async {
            await #expect(throws: PrismError.self, "\(label)") { _ = try await p.render(input, into: dest, using: renderer) }
        }
        let tiny = try texture([UInt8](repeating: 0, count: 64), width: 4, height: 4)
        let wrongFormat = try texture(src, format: .bgra8Unorm)
        let readOnly = try texture(src, usage: .shaderRead)
        let writeOnly = try texture(src, usage: .shaderWrite)
        await rejects("wrong size", tiny)
        await rejects("wrong format", wrongFormat)
        await rejects("no shaderWrite", readOnly)
        await rejects("no shaderRead", writeOnly)
        await rejects("same as input", input)
        // The wrong-size message says what the pipeline would have produced.
        do { _ = try await ImagePipeline { Resize(width: 5, height: 5) }.render(input, into: input, using: renderer) }
        catch let error as PrismError { #expect(error.localizedDescription.contains("5×5")) }
        #expect(bytes(input) == src)
        #expect(renderer.statistics.activeTextures == 0)
    }

    @Test("Metrics: no import/export, destination counted, input not")
    func metrics() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        let p = ImagePipeline { Exposure(0.1); Contrast(1.1); Exposure(-0.1) }
        let dest = try texture(src)
        let m = try await p.renderWithMetrics(try texture(src), into: dest, using: renderer).metrics
        #expect(m.importDuration == nil && m.exportDuration == nil)
        #expect(m.gpuDuration != nil && m.cpuEncodeDuration != nil)
        #expect(m.nodes.count == 3 && m.peakActiveTextures == 2, "two slots; one is the destination")
        #expect(m.textureAllocations == 1 && m.textureReuses == 0, "only the other slot came from the pool")
        let warm = try await p.renderWithMetrics(try texture(src), into: dest, using: renderer).metrics
        #expect(warm.textureAllocations == 0 && warm.textureReuses == 1)
        #expect(renderer.statistics.activeTextures == 0)
    }

    @Test("Concurrent texture renders, each with its own destination, are all correct")
    func concurrency() async throws {
        let renderer = try Renderer()
        let device = renderer.context.device
        let expected = bytes(try await ops.render(try texture(src), using: renderer))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let input = try self.texture(self.src, device: device), dest = try self.texture(self.src, device: device)
                    _ = try await self.ops.render(input, into: dest, using: renderer)
                    #expect(self.bytes(dest) == expected)
                }
            }
            try await group.waitForAll()
        }
        #expect(renderer.statistics.activeTextures == 0)
    }

    @Test("Cancellation before submission throws and returns every lease")
    func cancellation() async throws {
        let renderer = try Renderer()
        let input = try texture(src)
        // Run on this task, cancelled from outside: the texture never crosses an isolation boundary.
        let canceller = Task { try? await Task.sleep(for: .milliseconds(1)) }
        _ = canceller
        await withTaskCancellationHandler {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { _ = try await self.ops.render(input, using: renderer) }
        } onCancel: {}
        #expect(renderer.statistics.activeTextures == 0)
    }
}

@Suite("CGImage import layouts", .enabled(if: hasMetal))
struct ImportLayoutTests {
    let w = 19, h = 7

    private func image(
        _ bytes: [UInt8], bytesPerRow: Int? = nil, alpha: CGImageAlphaInfo, order: CGBitmapInfo = .byteOrder32Big,
        space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, bpc: Int = 8, bpp: Int = 32, w: Int? = nil, h: Int? = nil
    ) -> CGImage {
        CGImage(
            width: w ?? self.w, height: h ?? self.h, bitsPerComponent: bpc, bitsPerPixel: bpp, bytesPerRow: bytesPerRow ?? (w ?? self.w) * bpp / 8,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | order.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func upload(_ image: CGImage) throws -> [UInt8] {
        let ctx = try MetalContext()
        return CGImageInterop.readPixels(from: try CGImageInterop.makeTexture(from: image, context: ctx))
    }

    @Test("Native layout is detected, and the direct upload equals the redraw path")
    func nativeFastPath() throws {
        let src = testPixels(width: w, height: h)
        let img = image(src, alpha: .premultipliedLast)
        #expect(CGImageInterop.isNativeLayout(img))
        let ctx = try MetalContext()
        let direct = try ctx.makeTexture(width: w, height: h), redrawn = try ctx.makeTexture(width: w, height: h)
        try CGImageInterop.upload(img, to: direct)
        try CGImageInterop.uploadByRedrawing(img, to: redrawn)
        #expect(CGImageInterop.readPixels(from: direct) == src && CGImageInterop.readPixels(from: redrawn) == src)
    }

    @Test("Rows with padding (bytesPerRow > width·4) are read correctly")
    func paddedRows() throws {
        let src = testPixels(width: w, height: h)
        let stride = w * 4 + 12
        var padded = [UInt8](repeating: 0xEE, count: stride * h)
        for y in 0..<h { padded.replaceSubrange(y * stride..<y * stride + w * 4, with: src[y * w * 4..<(y + 1) * w * 4]) }
        let img = image(padded, bytesPerRow: stride, alpha: .premultipliedLast)
        #expect(CGImageInterop.isNativeLayout(img))
        #expect(try upload(img) == src)
    }

    @Test("Other layouts fall back to CoreGraphics and still give sRGB premultiplied RGBA")
    func fallbacks() throws {
        let src = testPixels(width: w, height: h)
        // BGRA premultiplied (what many system APIs produce).
        var bgra = src
        for i in stride(from: 0, to: src.count, by: 4) { bgra[i] = src[i + 2]; bgra[i + 2] = src[i] }
        let bgraImage = image(bgra, alpha: .premultipliedFirst, order: .byteOrder32Little)
        #expect(!CGImageInterop.isNativeLayout(bgraImage))
        #expect(try upload(bgraImage) == src)

        // Opaque RGBX: alpha becomes 255, color unchanged.
        var opaque = src
        for i in stride(from: 3, to: src.count, by: 4) { opaque[i] = 0 }
        let rgbx = try upload(image(opaque, alpha: .noneSkipLast))
        for i in stride(from: 0, to: rgbx.count, by: 4) { #expect(rgbx[i + 3] == 255 && rgbx[i] == src[i] && rgbx[i + 1] == src[i + 1] && rgbx[i + 2] == src[i + 2]) }

        // Straight (non-premultiplied) alpha is premultiplied on import.
        let straight: [UInt8] = [200, 100, 50, 128,  255, 255, 255, 0,  10, 20, 30, 255]
        let premultiplied = try upload(image(straight, alpha: .last, w: 3, h: 1))
        let expect = { (c: Int, a: Int) in Int((Double(c) * Double(a) / 255).rounded()) }
        #expect(abs(Int(premultiplied[0]) - expect(200, 128)) <= 1 && abs(Int(premultiplied[1]) - expect(100, 128)) <= 1 && abs(Int(premultiplied[2]) - expect(50, 128)) <= 1)
        #expect(premultiplied[3] == 128)
        #expect(Array(premultiplied[4..<8]) == [0, 0, 0, 0], "transparent pixels become transparent black")
        #expect(Array(premultiplied[8..<12]) == [10, 20, 30, 255])

        // Greyscale: replicated to RGB.
        var grey = [UInt8](repeating: 0, count: w * h)
        for i in 0..<grey.count { grey[i] = UInt8((i * 7) % 256) }
        let g = try upload(image(grey, alpha: .none, order: [], space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bpp: 8))
        #expect(g.count == w * h * 4)
        for i in 0..<(w * h) { #expect(g[i * 4] == g[i * 4 + 1] && g[i * 4 + 1] == g[i * 4 + 2] && g[i * 4 + 3] == 255) }
    }

    @Test("A wide-gamut image is converted to sRGB (documented): P3 neutral grey is preserved, P3 red clips")
    func displayP3() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let pixels: [UInt8] = [128, 128, 128, 255,  255, 0, 0, 255]
        let out = try upload(image(pixels, alpha: .premultipliedLast, space: p3, w: 2, h: 1))
        #expect(abs(Int(out[0]) - 128) <= 1 && abs(Int(out[1]) - 128) <= 1 && abs(Int(out[2]) - 128) <= 1)
        #expect(out[4] >= 250 && out[5] <= 5 && out[6] <= 5, "P3 red is outside sRGB and clips to (255,0,0): \(Array(out[4..<8]))")
    }
}
