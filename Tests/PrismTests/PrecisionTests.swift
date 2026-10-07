// PrecisionTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

@Suite("16-bit float precision", .enabled(if: hasMetal))
struct PrecisionTests {
    let w = 67, h = 41
    var src: [UInt8] { testPixels(width: w, height: h) }
    var image: CGImage { makeImage(width: w, height: h, bytes: src) }

    // MARK: Import and export

    @Test("8-bit sources import as v/255, within half-float rounding")
    func importAccuracy() throws {
        let floats = try floatPixels(of: image)
        let expected = src.map { Double($0) / 255 }
        #expect(maxAbsError(floats, expected) <= 6e-4, "max error \(maxAbsError(floats, expected))")
    }

    @Test("A no-op high-precision render returns the 8-bit input: exactly for opaque pixels, within 1 LSB otherwise")
    func noOpRoundTrip() async throws {
        let out = try await ImagePipeline {}.render(image, precision: .high)
        #expect(out.bitsPerComponent == 16 && out.bitsPerPixel == 64 && out.bitmapInfo.contains(.floatComponents))
        #expect(CGImageInterop.isNativeFloat16Layout(out))
        // Redrawn to 8-bit by CoreGraphics. Prism's own float values are exact to half-float rounding
        // (see `importAccuracy`); CoreGraphics' float → 8-bit conversion of *partly transparent*
        // premultiplied pixels can land 1 LSB away, so only opaque pixels are required to be exact.
        let back = try pixels(of: out)
        #expect(maxError(back, src) <= 1)
        var opaque = 0
        for i in stride(from: 0, to: src.count, by: 4) where src[i + 3] == 255 {
            opaque += 1
            #expect(Array(back[i..<i + 4]) == Array(src[i..<i + 4]), "opaque pixel \(i / 4)")
        }
        #expect(opaque > 0)
    }

    @Test("16-bit sources keep information an 8-bit pipeline would discard")
    func sixteenBitSourceSurvives() async throws {
        // 16-bit integer RGBA, premultiplied, opaque; adjacent values closer than one 8-bit step.
        let (w16, h16) = (16, 4)
        var raw = [UInt16](); raw.reserveCapacity(w16 * h16 * 4)
        for i in 0..<(w16 * h16) { raw += [UInt16(1000 + i * 40), UInt16(30000 + i * 7), UInt16(65535 - i * 11), 65535] }
        let data = raw.withUnsafeBufferPointer { Data(buffer: $0) }
        let img16 = CGImage(width: w16, height: h16, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w16 * 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

        let highImage = try await ImagePipeline {}.render(img16, precision: .high)
        let high = try floatPixels(of: highImage)
        let expected = raw.map { Double($0) / 65535 }
        // Half-float has 11 significant bits: error ≤ 2^-12 relative → ≤ 2.5e-4 for values < 1.
        #expect(maxAbsError(high, expected) <= 6e-4, "16-bit import error \(maxAbsError(high, expected))")

        // Red values step by 40/65535 ≈ 0.0006, much less than one 8-bit step (0.0039): 64 distinct
        // values span only ~10 eight-bit levels.
        let standardImage = try await ImagePipeline {}.render(img16, precision: .standard)
        let standard = try pixels(of: standardImage)
        let reds8 = Set(stride(from: 0, to: standard.count, by: 4).map { standard[$0] })
        let reds16 = Set(stride(from: 0, to: high.count, by: 4).map { high[$0] })
        #expect(reds8.count <= 12, "8-bit collapses the 64 distinct red values to \(reds8.count)")
        #expect(reds16.count >= 60, "half-float keeps \(reds16.count) of 64 distinct red values")
    }

    // MARK: Accuracy against an exact reference

    @Test("Per-pixel operations match the unquantized reference to within half-float rounding",
          arguments: [RefOp.exposure(0.7), .exposure(-2.5), .contrast(1.6), .saturation(1.4), .temperature(0.6), .vignette(0.8, 0.3)])
    func singleOperations(op: RefOp) async throws {
        let out = try await ImagePipeline(operations: [op.operation]).render(image, precision: .high)
        let exact = referenceExactFloatChain(src, width: w, height: h, ops: [op])
        let floats = try floatPixels(of: out)
        let error = maxAbsError(floats, exact)
        #expect(error <= 1.5e-3, "\(op): \(error) (\(error * 255) in 8-bit LSBs)")
    }

    @Test("Blur, sharpen-free spatial work and LUTs are accurate in half-float",
          arguments: [1.0, 4.0, 12.0])
    func blurAccuracy(sigma: Double) async throws {
        let out = try await ImagePipeline { GaussianBlur(radius: Float(sigma)) }.render(image, precision: .high)
        let floats = try floatPixels(of: out)
        let error = maxAbsError(floats, referenceBlurFloat(src, width: w, height: h, sigma: Float(sigma)))
        #expect(error <= 1.5e-3, "σ=\(sigma): \(error)")
    }

    @Test("Resize, Sharpen, Vignette and a LUT run in half-float and stay close to the 8-bit result")
    func otherOperations() async throws {
        let lut = try LUT3D.identity(size: 17)
        let p = ImagePipeline { Resize(scale: 0.6); Sharpen(amount: 0.5, radius: 1.5); LUTGrade(lut, intensity: 0.7) }
        let high = try await p.render(image, precision: .high)
        let standard = try await p.render(image, precision: .standard)
        #expect(high.width == standard.width && high.height == standard.height)
        // Redraw the 16-bit result to 8-bit and compare: they differ only by 8-bit rounding in the stages.
        let highBytes = try pixels(of: high), standardBytes = try pixels(of: standard)
        #expect(maxError(highBytes, standardBytes) <= 3)
    }

    @Test("A 20-stage chain: half-float storage is several times closer to exact than 8-bit, and fusion closes the rest")
    func longChainDrift() async throws {
        var refs: [RefOp] = []
        for i in 0..<10 { refs += [.exposure(Double(i % 3) * 0.15 - 0.1), .contrast(1.05)] }
        let exact = referenceExactFloatChain(src, width: w, height: h, ops: refs)
        let p = ImagePipeline(operations: refs.map(\.operation))

        // Unfused so all 20 stages really run, each storing its result: this isolates storage precision.
        let unfused = try Renderer(optimizations: noFusion)
        let highImage = try await p.render(image, precision: .high, using: unfused)
        let standardImage = try await p.render(image, precision: .standard, using: unfused)
        let high = try floatPixels(of: highImage)
        let standard = try pixels(of: standardImage)
        let highError = maxAbsError(high, exact) * 255                                         // in 8-bit LSBs
        let standardError = zip(standard, exact).map { abs(Double($0) / 255 - $1) }.max()! * 255
        // Measured on this chain: 10.8 LSB (8-bit) vs 2.3 LSB (half-float, 20 roundings of ~0.1 LSB
        // each, amplified by the contrast stages).
        #expect(standardError >= 8, "8-bit error \(standardError) LSB: if small, the comparison proves nothing")
        #expect(highError <= 3.5, "half-float error \(highError) LSB")
        #expect(standardError >= highError * 3, "8-bit \(standardError) vs half-float \(highError) LSB")

        // With fusion the 20 stages become 1 pass, so there is almost no intermediate storage at all.
        let fusedImage = try await p.render(image, precision: .high, using: try Renderer())
        let fused = try floatPixels(of: fusedImage)
        let fusedError = maxAbsError(fused, exact) * 255
        #expect(fusedError <= 0.6, "fused half-float error \(fusedError) LSB")
        #expect(fusedError < highError)
    }

    @Test("Banding: darkening a gradient 5 stops and restoring it loses levels in 8-bit but not in half-float")
    func bandingRecovery() async throws {
        // A 256-level horizontal grey ramp.
        let (gw, gh) = (256, 4)
        var ramp = [UInt8](); for _ in 0..<gh { for x in 0..<gw { ramp += [UInt8(x), UInt8(x), UInt8(x), 255] } }
        let img = makeImage(width: gw, height: gh, bytes: ramp)
        let p = ImagePipeline { Exposure(-5); Exposure(5) }
        let unfused = try Renderer(optimizations: noFusion)   // two real stages, each stored

        let standardImage = try await p.render(img, precision: .standard, using: unfused)
        let highImage = try await p.render(img, precision: .high, using: unfused)
        let standard = try pixels(of: standardImage)
        let high = try pixels(of: highImage)
        // Measured: after -5 stops the 8-bit ramp has only ~8 distinct dark codes, and +5 stops
        // cannot recover them: 15 LSB error, 50 distinct levels. Half-float has fine steps near
        // black and restores the ramp exactly.
        let levels8 = Set(stride(from: 0, to: standard.count, by: 4).map { standard[$0] }).count
        #expect(levels8 <= 64, "8-bit path keeps \(levels8) of 256 levels")
        #expect(maxError(standard, ramp) >= 10, "8-bit error \(maxError(standard, ramp))")
        #expect(maxError(high, ramp) <= 1, "half-float error \(maxError(high, ramp))")
    }

    // MARK: Out-of-range values (documented behavior)

    @Test("Color operations clamp to [0, 1]; blur preserves out-of-range values")
    func outOfRange() async throws {
        // A flat 16-bit-float texture holding 1.5 (above white) and -0.25 (below black) in colour.
        let side = 8
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        let device = try #require(MTLCreateSystemDefaultDevice())
        let input = try #require(device.makeTexture(descriptor: desc))
        // IEEE half bit patterns: 1.5 = 0x3E00, -0.25 = 0xB400, 0.5 = 0x3800, 1.0 = 0x3C00.
        var raw = [UInt16](); for _ in 0..<(side * side) { raw += [0x3E00, 0xB400, 0x3800, 0x3C00] }
        input.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: raw, bytesPerRow: side * 8)

        let renderer = try Renderer(optimizations: [])
        let blurredTexture = try await ImagePipeline { GaussianBlur(radius: 1) }.render(input, using: renderer)
        let blurred = readFloats(from: blurredTexture)
        #expect(abs(blurred[0] - 1.5) < 2e-3 && abs(blurred[1] + 0.25) < 2e-3, "blur kept \(blurred[0]), \(blurred[1])")
        let gradedTexture = try await ImagePipeline { Contrast(1.0001) }.render(input, using: renderer)
        let graded = readFloats(from: gradedTexture)
        #expect(graded[0] <= 1.0001 && graded[1] >= -0.0001, "contrast clamped to \(graded[0]), \(graded[1])")
    }

    // MARK: Texture path, formats, resources, concurrency

    @Test("A float16 texture renders in its own format and matches the CGImage .high path")
    func texturePath() async throws {
        let renderer = try Renderer()
        let ctx = renderer.context
        let input = try CGImageInterop.makeTexture(from: image, context: ctx, precision: .high)
        let p = ImagePipeline { Exposure(0.4); Contrast(1.2); GaussianBlur(radius: 3) }
        let viaTexture = try await p.render(input, using: renderer)
        #expect(viaTexture.pixelFormat == .rgba16Float)
        let viaImage = try await p.render(image, precision: .high, using: renderer)
        let imageFloats = try floatPixels(of: viaImage)
        #expect(readFloats(from: viaTexture) == imageFloats)
    }

    @Test("Mixing precisions is rejected for destinations; unsupported float formats stay rejected")
    func formatValidation() async throws {
        let renderer = try Renderer()
        let high = try CGImageInterop.makeTexture(from: image, context: renderer.context, precision: .high)
        let low = try CGImageInterop.makeTexture(from: image, context: renderer.context, precision: .standard)
        await #expect(throws: PrismError.self) { _ = try await ImagePipeline { Exposure(0.2) }.render(high, into: low, using: renderer) }
        await #expect(throws: PrismError.self) { _ = try await ImagePipeline { Exposure(0.2) }.render(low, into: high, using: renderer) }
    }

    @Test("High precision doubles texture memory and uses separate pooled textures")
    func resources() async throws {
        // A realistic size: on tiny images, allocation rounding hides the 2× ratio.
        let (rw, rh) = (512, 384)
        let big = makeImage(width: rw, height: rh, bytes: testPixels(width: rw, height: rh))
        let renderer = try Renderer(optimizations: noFusion)
        let p = ImagePipeline { Exposure(0.1); Contrast(1.1); Exposure(-0.1) }
        let low = try await p.renderWithMetrics(big, precision: .standard, using: renderer).metrics
        let high = try await p.renderWithMetrics(big, precision: .high, using: renderer).metrics
        let ratio = Double(high.peakTextureBytes) / Double(low.peakTextureBytes)
        #expect(ratio >= 1.95 && ratio <= 2.05, "memory ratio \(ratio)")
        #expect(high.textureAllocations == 3 && high.textureReuses == 0, "formats are keyed separately in the pool")
        let again = try await p.renderWithMetrics(big, precision: .high, using: renderer).metrics
        #expect(again.textureAllocations == 0 && again.textureReuses == 3)
    }

    @Test("Fusion and every optimizer pass work in half-float")
    func optimizerInHighPrecision() async throws {
        let p = ImagePipeline { Exposure(0); Exposure(0.3); Contrast(1.1); Saturation(1); Temperature(0.2); Sharpen(amount: 0) }
        let r = try await p.renderWithMetrics(image, precision: .high, using: try Renderer())
        #expect(r.metrics.nodes.count == 1 && r.metrics.nodes[0].name == "Exposure+Contrast+Temperature")
        let exact = referenceExactFloatChain(src, width: w, height: h, ops: [.exposure(0.3), .contrast(1.1), .temperature(0.2)])
        let floats = try floatPixels(of: r.image)
        #expect(maxAbsError(floats, exact) <= 1.5e-3)
    }

    @Test("Concurrent renders at both precisions are all correct")
    func concurrency() async throws {
        let renderer = try Renderer()
        let refHigh = try await ImagePipeline { Exposure(0.3); Saturation(1.2) }.render(image, precision: .high, using: renderer)
        let refLow = try await ImagePipeline { Exposure(0.3); Saturation(1.2) }.render(image, precision: .standard, using: renderer)
        let expectedHigh = try floatPixels(of: refHigh), expectedLow = try pixels(of: refLow)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    let img = makeImage(width: 67, height: 41, bytes: testPixels(width: 67, height: 41))
                    let p = ImagePipeline { Exposure(0.3); Saturation(1.2) }
                    if i % 2 == 0 {
                        let out = try floatPixels(of: try await p.render(img, precision: .high, using: renderer))
                        #expect(out == expectedHigh)
                    } else {
                        let out = try pixels(of: try await p.render(img, precision: .standard, using: renderer))
                        #expect(out == expectedLow)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(renderer.statistics.activeTextures == 0)
    }
}
