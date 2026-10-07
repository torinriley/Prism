// TestSupport.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import Metal
@testable import Prism

let hasMetal = MTLCreateSystemDefaultDevice() != nil

/// Builds an sRGB premultiplied-RGBA8 CGImage straight from bytes (no redraw).
func makeImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage {
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                 | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Deterministic, valid premultiplied pixels (rgb <= a), including fully transparent ones.
func testPixels(width: Int, height: Int) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let a = UInt8((x * 37 + y * 11) % 256)
            let scale = { (v: Int) in UInt8(Int(a) * (v % 256) / 255) }
            out += [scale(x * 13 + 5), scale(y * 29 + 3), scale(x * y + 101), a]
        }
    }
    return out
}

/// Raw RGBA8 bytes of a CGImage, redrawn through the same path Prism uses for upload.
func pixels(of image: CGImage) throws -> [UInt8] {
    let ctx = try MetalContext()
    return CGImageInterop.readPixels(from: try CGImageInterop.makeTexture(from: image, context: ctx))
}

/// Largest per-channel absolute difference, in 8-bit levels.
func maxError(_ a: [UInt8], _ b: [UInt8]) -> Int {
    precondition(a.count == b.count)
    return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
}

// MARK: CPU reference implementations (Double precision)

func srgbToLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func linearToSrgb(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

/// Applies `f` to straight (unpremultiplied) color of each premultiplied RGBA8 pixel.
func referenceMap(_ src: [UInt8], _ f: (Double) -> Double) -> [UInt8] {
    var out = src
    for i in stride(from: 0, to: src.count, by: 4) {
        let a = Double(src[i + 3]) / 255
        for c in 0..<3 {
            let straight = a > 0 ? Double(src[i + c]) / 255 / a : 0
            let v = min(max(f(straight), 0), 1) * a
            out[i + c] = UInt8((v * 255).rounded())
        }
    }
    return out
}

func referenceExposure(_ src: [UInt8], stops: Double) -> [UInt8] {
    referenceMap(src) { linearToSrgb(max(srgbToLinear($0) * pow(2, stops), 0)) }
}

func referenceContrast(_ src: [UInt8], factor: Double) -> [UInt8] {
    referenceMap(src) { ($0 - 0.5) * factor + 0.5 }
}

// MARK: Reference implementations for Phase 4 operations

typealias RGB = SIMD3<Double>

/// Applies `f` to the straight color of each pixel; `f` also receives the pixel coordinate.
func referencePixels(_ src: [UInt8], width: Int, _ f: (Int, Int, RGB) -> RGB) -> [UInt8] {
    var out = src
    for i in stride(from: 0, to: src.count, by: 4) {
        let x = (i / 4) % width, y = (i / 4) / width
        let a = Double(src[i + 3]) / 255
        let straight = a > 0 ? RGB(Double(src[i]), Double(src[i + 1]), Double(src[i + 2])) / 255 / a : .zero
        let v = f(x, y, straight).clamped(lowerBound: .zero, upperBound: .one) * a
        for c in 0..<3 { out[i + c] = UInt8((v[c] * 255).rounded()) }
    }
    return out
}

func lin(_ c: RGB) -> RGB { RGB(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z)) }
func enc(_ c: RGB) -> RGB { RGB(linearToSrgb(max(c.x, 0)), linearToSrgb(max(c.y, 0)), linearToSrgb(max(c.z, 0))) }

func referenceSaturation(_ src: [UInt8], width: Int, factor: Double) -> [UInt8] {
    referencePixels(src, width: width) { _, _, c in
        let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
        return RGB(repeating: luma) + (c - RGB(repeating: luma)) * factor
    }
}

func referenceTemperature(_ src: [UInt8], width: Int, shift: Double) -> [UInt8] {
    referencePixels(src, width: width) { _, _, c in
        enc(lin(c) * RGB(pow(2, 0.4 * shift), 1, pow(2, -0.4 * shift)))
    }
}

func referenceVignette(_ src: [UInt8], width: Int, height: Int, amount: Double, radius: Double) -> [UInt8] {
    referencePixels(src, width: width) { x, y, c in
        let u = (Double(x) + 0.5) / Double(width) - 0.5, v = (Double(y) + 0.5) / Double(height) - 0.5
        let d = (u * u + v * v).squareRoot() * 2.0.squareRoot()
        let t = min(max((d - radius) / (1 - radius), 0), 1)
        return enc(lin(c) * (1 - amount * t * t * (3 - 2 * t)))
    }
}

/// One separable pass over premultiplied bytes, rounding to 8 bits like the GPU's intermediate texture.
func referenceBlurPass(_ src: [UInt8], width: Int, height: Int, sigma: Float, horizontal: Bool) -> [UInt8] {
    let (radius, weights) = gaussianKernel(sigma: sigma)
    var out = src
    for y in 0..<height { for x in 0..<width { for c in 0..<4 {
        var acc = 0.0
        for i in -radius...radius {
            let sx = horizontal ? min(max(x + i, 0), width - 1) : x
            let sy = horizontal ? y : min(max(y + i, 0), height - 1)
            acc += Double(weights[i + radius]) * Double(src[(sy * width + sx) * 4 + c])
        }
        out[(y * width + x) * 4 + c] = UInt8(min(max(acc.rounded(), 0), 255))
    } } }
    return out
}

func referenceBlur(_ src: [UInt8], width: Int, height: Int, sigma: Float) -> [UInt8] {
    referenceBlurPass(
        referenceBlurPass(src, width: width, height: height, sigma: sigma, horizontal: true),
        width: width, height: height, sigma: sigma, horizontal: false)
}

func referenceSharpen(_ src: [UInt8], width: Int, height: Int, amount: Double, sigma: Float) -> [UInt8] {
    let blurred = referenceBlur(src, width: width, height: height, sigma: sigma)
    var out = src
    for i in stride(from: 0, to: src.count, by: 4) {
        let a = Double(src[i + 3])
        for c in 0..<3 {
            let o = Double(src[i + c])
            out[i + c] = UInt8(min(max(o + amount * (o - Double(blurred[i + c])), 0), a).rounded())
        }
    }
    return out
}

func referenceResizeBilinear(_ src: [UInt8], from: (w: Int, h: Int), to: (w: Int, h: Int)) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: to.w * to.h * 4)
    let sx = Double(from.w) / Double(to.w), sy = Double(from.h) / Double(to.h)
    for y in 0..<to.h { for x in 0..<to.w {
        let px = (Double(x) + 0.5) * sx - 0.5, py = (Double(y) + 0.5) * sy - 0.5
        let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
        let tx = px - Double(x0), ty = py - Double(y0)
        let cx = { min(max($0, 0), from.w - 1) }, cy = { min(max($0, 0), from.h - 1) }
        for c in 0..<4 {
            let at = { (xx: Int, yy: Int) in Double(src[(cy(yy) * from.w + cx(xx)) * 4 + c]) }
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            out[(y * to.w + x) * 4 + c] = UInt8((top * (1 - ty) + bottom * ty).rounded())
        }
    } }
    return out
}

func referenceLUT(_ src: [UInt8], width: Int, lut: LUT3D, intensity: Double) -> [UInt8] {
    let n = lut.size
    let at = { (r: Int, g: Int, b: Int) -> RGB in
        let i = ((b * n + g) * n + r) * 3
        return RGB(Double(lut.rgb[i]), Double(lut.rgb[i + 1]), Double(lut.rgb[i + 2]))
    }
    return referencePixels(src, width: width) { _, _, c in
        let p = c * Double(n - 1)
        let r0 = Int(p.x.rounded(.down)), g0 = Int(p.y.rounded(.down)), b0 = Int(p.z.rounded(.down))
        let t = RGB(p.x - Double(r0), p.y - Double(g0), p.z - Double(b0))
        let r1 = min(r0 + 1, n - 1), g1 = min(g0 + 1, n - 1), b1 = min(b0 + 1, n - 1)
        let l = { (a: RGB, b: RGB, t: Double) in a * (1 - t) + b * t }
        let c00 = l(at(r0, g0, b0), at(r1, g0, b0), t.x), c10 = l(at(r0, g1, b0), at(r1, g1, b0), t.x)
        let c01 = l(at(r0, g0, b1), at(r1, g0, b1), t.x), c11 = l(at(r0, g1, b1), at(r1, g1, b1), t.x)
        let graded = l(l(c00, c10, t.y), l(c01, c11, t.y), t.z)
        return l(c, graded.clamped(lowerBound: .zero, upperBound: .one), intensity)
    }
}

/// Everything except fusion. Tests of pool sizing, cache counters, slot reuse and per-pass
/// metrics use chains of per-pixel operations; they pin this so fusion doesn't collapse the
/// chain they are examining. Fusion has its own tests.
let noFusion: OptimizationOptions = [.identityElimination, .deadNodeElimination]

// MARK: Exact (unquantized) reference chains

/// A per-pixel operation described by its parameters, for building a pipeline and its reference together.
enum RefOp {
    case exposure(Double), contrast(Double), saturation(Double), temperature(Double), vignette(Double, Double)

    var operation: any ImageOperation {
        switch self {
        case .exposure(let v): Exposure(Float(v))
        case .contrast(let v): Contrast(Float(v))
        case .saturation(let v): Saturation(Float(v))
        case .temperature(let v): Temperature(Float(v))
        case .vignette(let a, let r): Vignette(amount: Float(a), radius: Float(r))
        }
    }

    func apply(_ c: RGB, x: Int, y: Int, width: Int, height: Int) -> RGB {
        let result: RGB
        switch self {
        case .exposure(let v): result = enc(lin(c) * pow(2, v))
        case .contrast(let v): result = (c - 0.5) * v + 0.5
        case .saturation(let v):
            let l = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
            result = RGB(repeating: l) + (c - RGB(repeating: l)) * v
        case .temperature(let v): result = enc(lin(c) * RGB(pow(2, 0.4 * v), 1, pow(2, -0.4 * v)))
        case .vignette(let amount, let radius):
            let u = (Double(x) + 0.5) / Double(width) - 0.5, w = (Double(y) + 0.5) / Double(height) - 0.5
            let d = (u * u + w * w).squareRoot() * 2.0.squareRoot()
            let t = min(max((d - radius) / (1 - radius), 0), 1)
            result = enc(lin(c) * (1 - amount * t * t * (3 - 2 * t)))
        }
        // Every operation clamps its own result to [0, 1], as the kernels do.
        return result.clamped(lowerBound: .zero, upperBound: .one)
    }
}

/// Applies `ops` in Double precision with **no rounding between operations** (only the final
/// conversion to 8 bits): the ideal result a perfect chain would produce from the 8-bit input.
func referenceExactChain(_ src: [UInt8], width: Int, height: Int, ops: [RefOp]) -> [UInt8] {
    referencePixels(src, width: width) { x, y, c in
        ops.reduce(c) { $1.apply($0, x: x, y: y, width: width, height: height) }
    }
}

// MARK: 16-bit float helpers

/// IEEE half-precision bits → Float (portable: no `Float16`, which is unavailable on Intel Macs).
func halfToFloat(_ h: UInt16) -> Float {
    let sign: UInt32 = UInt32(h >> 15) << 31
    let exponent = Int((h >> 10) & 0x1F), mantissa = UInt32(h & 0x3FF)
    if exponent == 0 {
        let magnitude = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
        return sign == 0 ? magnitude : -magnitude
    }
    if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
    return Float(bitPattern: sign | UInt32(exponent + 112) << 23 | mantissa << 13)
}

/// Premultiplied RGBA values of an `rgba16Float` texture.
func readFloats(from texture: any MTLTexture) -> [Float] {
    let bytes = CGImageInterop.readPixels(from: texture)
    return stride(from: 0, to: bytes.count, by: 2).map { halfToFloat(UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
}

/// Premultiplied RGBA floats of any CGImage, imported through Prism's 16-bit float path.
func floatPixels(of image: CGImage) throws -> [Float] {
    let ctx = try MetalContext()
    return readFloats(from: try CGImageInterop.makeTexture(from: image, context: ctx, precision: .high))
}

/// Largest absolute difference.
func maxAbsError(_ a: [Float], _ b: [Double]) -> Double {
    precondition(a.count == b.count)
    return zip(a, b).map { abs(Double($0) - $1) }.max() ?? 0
}

/// 8-bit input → premultiplied RGBA doubles in [0, 1], *no* rounding after any operation.
func referenceExactFloatChain(_ src: [UInt8], width: Int, height: Int, ops: [RefOp]) -> [Double] {
    var out = [Double](repeating: 0, count: src.count)
    for i in stride(from: 0, to: src.count, by: 4) {
        let x = (i / 4) % width, y = (i / 4) / width
        let a = Double(src[i + 3]) / 255
        var c = a > 0 ? RGB(Double(src[i]), Double(src[i + 1]), Double(src[i + 2])) / 255 / a : .zero
        for op in ops { c = op.apply(c, x: x, y: y, width: width, height: height) }
        out[i] = c.x * a; out[i + 1] = c.y * a; out[i + 2] = c.z * a; out[i + 3] = a
    }
    return out
}

/// Exact Gaussian blur of premultiplied doubles (separable, clamped edges, same taps as Prism).
func referenceBlurFloat(_ src: [UInt8], width: Int, height: Int, sigma: Float) -> [Double] {
    let (radius, weights) = gaussianKernel(sigma: sigma)
    var current = src.map { Double($0) / 255 }
    for horizontal in [true, false] {
        var next = current
        for y in 0..<height { for x in 0..<width { for c in 0..<4 {
            var acc = 0.0
            for i in -radius...radius {
                let sx = horizontal ? min(max(x + i, 0), width - 1) : x
                let sy = horizontal ? y : min(max(y + i, 0), height - 1)
                acc += Double(weights[i + radius]) * current[(sy * width + sx) * 4 + c]
            }
            next[(y * width + x) * 4 + c] = acc
        } } }
        current = next
    }
    return current
}
