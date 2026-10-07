// OperationTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Testing
@testable import Prism

/// Renders `ops` over a deterministic test image and returns the output bytes.
private func render(_ ops: [any ImageOperation], width: Int, height: Int, bytes: [UInt8]? = nil,
                    renderer: Renderer? = nil) async throws -> (out: [UInt8], size: ImageSize) {
    let src = bytes ?? testPixels(width: width, height: height)
    let out = try await ImagePipeline(operations: ops).render(makeImage(width: width, height: height, bytes: src), using: renderer)
    return (try pixels(of: out), ImageSize(width: out.width, height: out.height))
}

private let sizes: [(Int, Int)] = [(1, 1), (2, 2), (3, 5), (17, 9), (64, 33), (131, 77)]

@Suite("Color operations", .enabled(if: hasMetal))
struct ColorOperationTests {
    @Test("Saturation matches reference", arguments: [0.0, 0.5, 1.0, 1.7, 4.0], sizes)
    func saturation(factor: Double, size: (Int, Int)) async throws {
        let src = testPixels(width: size.0, height: size.1)
        let (out, _) = try await render([Saturation(Float(factor))], width: size.0, height: size.1)
        #expect(maxError(out, referenceSaturation(src, width: size.0, factor: factor)) <= 1)
    }

    @Test("Saturation(1) is an exact identity")
    func saturationIdentity() async throws {
        let src = testPixels(width: 64, height: 33)
        let (out, _) = try await render([Saturation(1)], width: 64, height: 33)
        #expect(out == src)
    }

    @Test("Saturation(0) produces equal RGB channels")
    func greyscale() async throws {
        let (out, _) = try await render([Saturation(0)], width: 31, height: 19)
        for i in stride(from: 0, to: out.count, by: 4) {
            #expect(abs(Int(out[i]) - Int(out[i + 1])) <= 1 && abs(Int(out[i + 1]) - Int(out[i + 2])) <= 1)
        }
    }

    @Test("Temperature matches reference", arguments: [-1.0, -0.3, 0.0, 0.6, 1.0], sizes)
    func temperature(shift: Double, size: (Int, Int)) async throws {
        let src = testPixels(width: size.0, height: size.1)
        let (out, _) = try await render([Temperature(Float(shift))], width: size.0, height: size.1)
        #expect(maxError(out, referenceTemperature(src, width: size.0, shift: shift)) <= 1)
    }

    @Test("Temperature(0) is an exact identity; warm raises red relative to blue")
    func temperatureBehaviour() async throws {
        let grey: [UInt8] = (0..<16).flatMap { _ in [UInt8(128), 128, 128, 255] }
        let (same, _) = try await render([Temperature(0)], width: 4, height: 4, bytes: grey)
        #expect(same == grey)
        let (warm, _) = try await render([Temperature(0.5)], width: 4, height: 4, bytes: grey)
        #expect(warm[0] > warm[1] && warm[1] > warm[2])
    }

    @Test("Parameter validation", arguments: [Float.nan, .infinity, -0.01, 4.01])
    func validation(value: Float) async throws {
        await #expect(throws: PrismError.self) { _ = try await render([Saturation(value)], width: 2, height: 2) }
        await #expect(throws: PrismError.self) { _ = try await render([Contrast(value)], width: 2, height: 2) }
    }

    @Test("Temperature validation", arguments: [Float.nan, -1.01, 1.01])
    func temperatureValidation(value: Float) async throws {
        await #expect(throws: PrismError.self) { _ = try await render([Temperature(value)], width: 2, height: 2) }
    }

    @Test("Extreme parameters keep alpha untouched and rgb <= alpha")
    func validPremultiplied() async throws {
        let src = testPixels(width: 50, height: 40)
        let (out, _) = try await render([Exposure(10), Saturation(4), Contrast(4), Temperature(1)], width: 50, height: 40)
        for i in stride(from: 0, to: out.count, by: 4) {
            #expect(out[i + 3] == src[i + 3])
            #expect(out[i] <= out[i + 3] && out[i + 1] <= out[i + 3] && out[i + 2] <= out[i + 3])
        }
    }

    @Test("Large image (4096×2160) is processed correctly (sampled)")
    func large() async throws {
        let (w, h) = (4096, 2160)
        let src = testPixels(width: w, height: h)
        let (out, size) = try await render([Exposure(0.7)], width: w, height: h, bytes: src)
        #expect(size == ImageSize(width: w, height: h))
        // Compare a strided sample (including the last pixel) against the reference.
        var picked: [Int] = Array(stride(from: 0, to: w * h, by: 997)); picked.append(w * h - 1)
        let sampleSrc = picked.flatMap { Array(src[$0 * 4..<$0 * 4 + 4]) }
        let sampleOut = picked.flatMap { Array(out[$0 * 4..<$0 * 4 + 4]) }
        #expect(maxError(sampleOut, referenceExposure(sampleSrc, stops: 0.7)) <= 1)
    }
}

@Suite("Spatial operations", .enabled(if: hasMetal))
struct SpatialOperationTests {
    @Test("Gaussian kernel is normalized, symmetric, and monotone")
    func kernelProperties() {
        for sigma in [Float(0.1), 0.5, 1, 2.5, 8, 64] {
            let (radius, w) = gaussianKernel(sigma: sigma)
            #expect(w.count == 2 * radius + 1)
            #expect(abs(w.reduce(0, +) - 1) < 1e-5)
            for i in 0..<radius { #expect(w[i] == w[w.count - 1 - i]); #expect(w[i] <= w[i + 1]) }
        }
        #expect(gaussianKernel(sigma: 2).radius == 6)
    }

    @Test("Blur matches the separable reference", arguments: [0.5, 1.0, 3.0, 8.0], sizes)
    func blur(sigma: Double, size: (Int, Int)) async throws {
        let src = testPixels(width: size.0, height: size.1)
        let (out, _) = try await render([GaussianBlur(radius: Float(sigma))], width: size.0, height: size.1)
        let err = maxError(out, referenceBlur(src, width: size.0, height: size.1, sigma: Float(sigma)))
        #expect(err <= 1, "\(size) σ=\(sigma): \(err) LSB")
    }

    @Test("Blur at the maximum radius on a tiny image (everything clamps)")
    func blurMax() async throws {
        let src = testPixels(width: 3, height: 2)
        let (out, _) = try await render([GaussianBlur(radius: 64)], width: 3, height: 2)
        #expect(maxError(out, referenceBlur(src, width: 3, height: 2, sigma: 64)) <= 1)
    }

    @Test("Blur(radius: 0) is an exact identity and is flagged for elimination")
    func blurIdentity() async throws {
        let plan = try GaussianBlur(radius: 0).plan(inputSize: .init(width: 4, height: 4))
        #expect(!plan.steps.isEmpty && plan.steps.allSatisfy(\.pass.isIdentity))
        let src = testPixels(width: 20, height: 11)
        let (out, _) = try await render([GaussianBlur(radius: 0)], width: 20, height: 11)
        #expect(out == src)
    }

    @Test("A constant image is unchanged by blur, including at borders")
    func blurConstant() async throws {
        let flat: [UInt8] = (0..<(23 * 17)).flatMap { _ in [UInt8(90), 120, 30, 200] }
        let (out, _) = try await render([GaussianBlur(radius: 5)], width: 23, height: 17, bytes: flat)
        #expect(maxError(out, flat) <= 1)
    }

    @Test("Impulse response is symmetric, peaks at the impulse, and conserves energy")
    func impulse() async throws {
        let n = 41
        var img = [UInt8](repeating: 0, count: n * n * 4)
        let center = (20 * n + 20) * 4
        img[center] = 255; img[center + 3] = 255
        let (out, _) = try await render([GaussianBlur(radius: 2)], width: n, height: n, bytes: img)
        let red = { (x: Int, y: Int) in Int(out[(y * n + x) * 4]) }
        #expect(red(20, 20) == (0..<n).flatMap { y in (0..<n).map { red($0, y) } }.max())
        for d in 1...5 { #expect(abs(red(20 + d, 20) - red(20 - d, 20)) <= 1 && abs(red(20, 20 + d) - red(20, 20 - d)) <= 1) }
        let total = (0..<n).flatMap { y in (0..<n).map { red($0, y) } }.reduce(0, +)
        // 8-bit rounding of many small tails loses/gains a little; 255 ± 10% is a loose sanity bound.
        #expect(abs(Double(total) - 255) < 25, "total \(total)")
    }

    @Test("Blur validation", arguments: [Float.nan, -1, 64.5])
    func blurValidation(value: Float) async throws {
        await #expect(throws: PrismError.self) { _ = try await render([GaussianBlur(radius: value)], width: 2, height: 2) }
    }

    @Test("Sharpen matches reference", arguments: [0.3, 1.0, 5.0], sizes)
    func sharpen(amount: Double, size: (Int, Int)) async throws {
        let src = testPixels(width: size.0, height: size.1)
        let (out, _) = try await render([Sharpen(amount: Float(amount), radius: 1.5)], width: size.0, height: size.1)
        let err = maxError(out, referenceSharpen(src, width: size.0, height: size.1, amount: amount, sigma: 1.5))
        #expect(err <= 1, "\(size) amount=\(amount): \(err) LSB")
    }

    @Test("Sharpen(amount: 0) is an exact identity; Sharpen increases edge contrast")
    func sharpenBehaviour() async throws {
        let src = testPixels(width: 30, height: 30)
        let (same, _) = try await render([Sharpen(amount: 0)], width: 30, height: 30)
        #expect(same == src)

        // A vertical step edge: left dark, right bright.
        let n = 16
        var edge = [UInt8](); for _ in 0..<n { for x in 0..<n { edge += x < n / 2 ? [60, 60, 60, 255] : [180, 180, 180, 255] } }
        let (sharp, _) = try await render([Sharpen(amount: 1)], width: n, height: n, bytes: edge)
        let row = { (x: Int) in Int(sharp[(8 * n + x) * 4]) }
        #expect(row(n / 2 - 1) < 60 && row(n / 2) > 180, "overshoot expected at the edge")
        #expect(row(0) == 60 && row(n - 1) == 180, "flat regions far from the edge are unchanged")
    }

    @Test("Sharpen validation")
    func sharpenValidation() async throws {
        for op in [Sharpen(amount: -1), Sharpen(amount: 6), Sharpen(amount: 1, radius: 0), Sharpen(amount: 1, radius: .nan)] {
            await #expect(throws: PrismError.self) { _ = try await render([op], width: 2, height: 2) }
        }
    }

    @Test("Resize matches the bilinear reference",
          arguments: [((17, 9), (5, 3)), ((17, 9), (40, 22)), ((4, 4), (1, 1)), ((1, 1), (7, 5)), ((64, 64), (32, 32)), ((9, 31), (9, 7))] as [((Int, Int), (Int, Int))])
    func resize(pair: ((Int, Int), (Int, Int))) async throws {
        let (from, to) = pair
        let src = testPixels(width: from.0, height: from.1)
        let (out, size) = try await render([Resize(width: to.0, height: to.1)], width: from.0, height: from.1)
        #expect(size == ImageSize(width: to.0, height: to.1))
        let err = maxError(out, referenceResizeBilinear(src, from: from, to: to))
        #expect(err <= 1, "\(from) → \(to): \(err) LSB")
    }

    @Test("Resizing to the same size is an exact identity; 2× downscale averages 2×2 blocks")
    func resizeKnownValues() async throws {
        let src = testPixels(width: 8, height: 6)
        let (same, _) = try await render([Resize(width: 8, height: 6)], width: 8, height: 6)
        #expect(same == src)

        let (half, size) = try await render([Resize(scale: 0.5)], width: 8, height: 6)
        #expect(size == ImageSize(width: 4, height: 3))
        for y in 0..<3 { for x in 0..<4 { for c in 0..<4 {
            let sum = [(0, 0), (1, 0), (0, 1), (1, 1)].map { Double(src[((2 * y + $0.1) * 8 + 2 * x + $0.0) * 4 + c]) }.reduce(0, +)
            #expect(abs(Double(half[(y * 4 + x) * 4 + c]) - sum / 4) <= 1)
        } } }
    }

    @Test("Upscaling a constant image stays constant (border clamping)")
    func resizeConstant() async throws {
        let flat: [UInt8] = (0..<9).flatMap { _ in [UInt8(10), 200, 60, 255] }
        let (out, size) = try await render([Resize(width: 31, height: 17)], width: 3, height: 3, bytes: flat)
        #expect(size == ImageSize(width: 31, height: 17))
        let expected: [UInt8] = (0..<(31 * 17)).flatMap { _ in [UInt8(10), 200, 60, 255] }
        #expect(out == expected)
    }

    @Test("Operations after a Resize see the new size")
    func resizeThenVignette() async throws {
        let src = testPixels(width: 20, height: 10)
        let (out, size) = try await render([Resize(width: 12, height: 14), Vignette(amount: 0.8)], width: 20, height: 10)
        #expect(size == ImageSize(width: 12, height: 14))
        let resized = referenceResizeBilinear(src, from: (20, 10), to: (12, 14))
        #expect(maxError(out, referenceVignette(resized, width: 12, height: 14, amount: 0.8, radius: 0.5)) <= 2)
    }

    @Test("Resize validation")
    func resizeValidation() async throws {
        for op in [Resize(width: 0, height: 4), Resize(width: 4, height: -1), Resize(width: 16385, height: 4),
                   Resize(scale: 0), Resize(scale: -2), Resize(scale: .nan), Resize(scale: .infinity)] {
            await #expect(throws: PrismError.self) { _ = try await render([op], width: 4, height: 4) }
        }
    }

    @Test("Many-stage pipeline with a size change, a branch (Sharpen), and every spatial op")
    func mixedPipeline() async throws {
        let (out, size) = try await render(
            [Exposure(0.3), GaussianBlur(radius: 2), Resize(scale: 0.5), Sharpen(amount: 0.5), Vignette(amount: 0.4), Saturation(0.9)],
            width: 91, height: 63)
        #expect(size == ImageSize(width: 46, height: 32))
        #expect(out.count == 46 * 32 * 4)
    }
}

@Suite("Effects and LUT", .enabled(if: hasMetal))
struct EffectOperationTests {
    @Test("Vignette matches reference", arguments: [(0.3, 0.0), (1.0, 0.5), (0.7, 0.95)], sizes)
    func vignette(params: (Double, Double), size: (Int, Int)) async throws {
        let src = testPixels(width: size.0, height: size.1)
        let (out, _) = try await render([Vignette(amount: Float(params.0), radius: Float(params.1))], width: size.0, height: size.1)
        let err = maxError(out, referenceVignette(src, width: size.0, height: size.1, amount: params.0, radius: params.1))
        #expect(err <= 1, "\(size) \(params): \(err) LSB")
    }

    @Test("Vignette(0) is an identity; the center is untouched; corners darken")
    func vignetteBehaviour() async throws {
        let white = [UInt8](repeating: 255, count: 51 * 51 * 4)
        let (same, _) = try await render([Vignette(amount: 0)], width: 51, height: 51, bytes: white)
        #expect(same == white)
        let (out, _) = try await render([Vignette(amount: 1, radius: 0.3)], width: 51, height: 51, bytes: white)
        let px = { (x: Int, y: Int) in Int(out[(y * 51 + x) * 4]) }
        #expect(px(25, 25) == 255)
        #expect(px(0, 0) < 10 && px(50, 50) < 10 && px(0, 50) < 10)
        #expect(px(0, 0) == px(50, 50) && px(0, 50) == px(50, 0), "symmetric")
    }

    @Test("Vignette validation", arguments: [Float.nan, -0.1, 1.1])
    func vignetteValidation(value: Float) async throws {
        await #expect(throws: PrismError.self) { _ = try await render([Vignette(amount: value)], width: 2, height: 2) }
        await #expect(throws: PrismError.self) { _ = try await render([Vignette(amount: 0.5, radius: value)], width: 2, height: 2) }
    }

    private func curvedLUT(size n: Int) throws -> LUT3D {
        var v: [Float] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let (x, y, z) = (Float(r) / Float(n - 1), Float(g) / Float(n - 1), Float(b) / Float(n - 1))
            v += [1 - z, x * y, y * y]   // non-trivial: channel swap, product, curve
        } } }
        return try LUT3D(size: n, rgb: v)
    }

    @Test("Identity LUT reproduces the image", arguments: [2, 17, 33])
    func identityLUT(size n: Int) async throws {
        let src = testPixels(width: 64, height: 33)
        let (out, _) = try await render([LUTGrade(try .identity(size: n))], width: 64, height: 33)
        #expect(maxError(out, src) <= 1)
    }

    @Test("LUT matches the trilinear reference", arguments: [2, 5, 33], [0.0, 0.4, 1.0])
    func lut(size n: Int, intensity: Double) async throws {
        let lut = try curvedLUT(size: n)
        let src = testPixels(width: 53, height: 31)
        let (out, _) = try await render([LUTGrade(lut, intensity: Float(intensity))], width: 53, height: 31)
        let err = maxError(out, referenceLUT(src, width: 53, lut: lut, intensity: intensity))
        #expect(err <= 1, "size \(n) intensity \(intensity): \(err) LSB")
    }

    @Test("LUT corner entries are hit exactly; 1×1 and transparent pixels work")
    func lutCorners() async throws {
        let lut = try curvedLUT(size: 9)
        // Opaque black (lattice 0,0,0 → (1, 0, 0)) and opaque white (1,1,1 → (0, 1, 1)).
        let (out, _) = try await render([LUTGrade(lut)], width: 2, height: 1, bytes: [0, 0, 0, 255, 255, 255, 255, 255])
        #expect(out == [255, 0, 0, 255, 0, 255, 255, 255])
        let (clear, _) = try await render([LUTGrade(lut)], width: 1, height: 1, bytes: [0, 0, 0, 0])
        #expect(clear == [0, 0, 0, 0], "fully transparent stays fully transparent")
    }

    @Test(".cube parsing: round trip, comments, and rejection of unsupported input")
    func cubeParsing() throws {
        let text = """
        # comment
        TITLE "test"
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try LUT3D(cube: text)
        let identity = try LUT3D.identity(size: 2)
        #expect(lut.size == 2 && lut.rgb == identity.rgb)

        for bad in ["LUT_1D_SIZE 2\n0 0 0\n1 1 1", "DOMAIN_MAX 2 2 2\nLUT_3D_SIZE 2", "LUT_3D_SIZE 2\n0 0 0",
                    "0 0 0", "LUT_3D_SIZE 2\n" + String(repeating: "a b c\n", count: 8), "LUT_3D_SIZE 1\n0 0 0"] {
            #expect(throws: PrismError.self, "should reject: \(bad.prefix(30))") { try LUT3D(cube: bad) }
        }
        #expect(throws: PrismError.self) { try LUT3D(size: 2, rgb: [Float](repeating: .nan, count: 24)) }
    }

    @Test("LUT intensity validation")
    func lutValidation() async throws {
        let id = try LUT3D.identity(size: 2)
        for v in [Float.nan, -0.1, 1.1] {
            await #expect(throws: PrismError.self) { _ = try await render([LUTGrade(id, intensity: v)], width: 2, height: 2) }
        }
    }
}
