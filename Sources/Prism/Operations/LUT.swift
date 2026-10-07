// LUT.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation

/// A 3D color lookup table.
///
/// **Format.** `size`³ RGB entries, `Float`, red index varying fastest, then green, then
/// blue (the `.cube` layout). Entry (r, g, b) holds the output color for the input color
/// (r, g, b) / (size − 1). Values are expected in 0...1 and are clamped on output.
///
/// **Color assumptions.** Input and output are *straight* (unpremultiplied),
/// **sRGB-encoded** colors on a 0...1 domain, i.e. display-referred. Prism does not
/// convert between color spaces: a LUT authored for log or linear input will give wrong
/// results if applied to sRGB-encoded images.
///
/// **Interpolation.** Trilinear, computed in the shader from 8 exact lattice reads.
public struct LUT3D: Sendable {
    public let size: Int
    /// `size³` RGB triples, red fastest.
    let rgb: [Float]
    /// Identifies this LUT's contents for texture caching. A LUT is immutable, so copies of it
    /// share the id (and one cached texture); two separately built LUTs never do, even if equal.
    let id = UUID()

    /// - Parameters:
    ///   - size: Lattice points per axis, 2...256.
    ///   - rgb: `size³ · 3` floats, red fastest.
    public init(size: Int, rgb: [Float]) throws {
        guard (2...256).contains(size) else {
            throw PrismError.invalidLUT(reason: "size \(size) is outside 2...256")
        }
        guard rgb.count == size * size * size * 3 else {
            throw PrismError.invalidLUT(reason: "expected \(size * size * size * 3) values for size \(size), got \(rgb.count)")
        }
        guard rgb.allSatisfy(\.isFinite) else {
            throw PrismError.invalidLUT(reason: "contains non-finite values")
        }
        self.size = size
        self.rgb = rgb
    }

    /// A LUT that maps every color to itself (up to float rounding).
    public static func identity(size: Int) throws -> LUT3D {
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        let scale = Float(max(size - 1, 1))
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            values += [Float(r) / scale, Float(g) / scale, Float(b) / scale]
        } } }
        return try LUT3D(size: size, rgb: values)
    }

    /// Parses an Adobe/IRIDAS `.cube` 3D LUT.
    ///
    /// Supported: `LUT_3D_SIZE`, `TITLE`, comments, and `DOMAIN_MIN/MAX` of exactly 0…1.
    /// Not supported: 1D LUTs and other domains (rejected with `PrismError.invalidLUT`).
    public init(cube text: String) throws {
        var size: Int?
        var values: [Float] = []
        for (number, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            switch parts[0] {
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else {
                    throw PrismError.invalidLUT(reason: "line \(number + 1): malformed LUT_3D_SIZE")
                }
                size = n
            case "LUT_1D_SIZE", "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE":
                throw PrismError.invalidLUT(reason: "line \(number + 1): '\(parts[0])' is not supported")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let expected: Float = parts[0] == "DOMAIN_MIN" ? 0 : 1
                let v = parts.dropFirst().compactMap { Float($0) }
                guard v.count == 3, v.allSatisfy({ $0 == expected }) else {
                    throw PrismError.invalidLUT(reason: "line \(number + 1): only a 0…1 domain is supported")
                }
            default:
                let v = parts.compactMap { Float($0) }
                guard v.count == 3, parts.count == 3 else {
                    throw PrismError.invalidLUT(reason: "line \(number + 1): expected three numbers")
                }
                values += v
            }
        }
        guard let size else { throw PrismError.invalidLUT(reason: "missing LUT_3D_SIZE") }
        try self.init(size: size, rgb: values)
    }

    /// Loads a `.cube` file. See ``init(cube:)``.
    public init(cubeFileAt url: URL) throws {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch { throw PrismError.invalidLUT(reason: "could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        try self.init(cube: text)
    }
}

/// Applies a 3D LUT to the image. See ``LUT3D`` for format, interpolation and color assumptions.
public struct LUTGrade: ImageOperation {
    public var lut: LUT3D
    /// Blend between the original (0) and fully graded (1) color. Valid range: 0...1.
    public var intensity: Float
    public init(_ lut: LUT3D, intensity: Float = 1) {
        self.lut = lut
        self.intensity = intensity
    }
    public var name: String { "LUTGrade" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(intensity, in: 0...1, operation: name, parameter: "intensity")
        struct Uniforms { var size: Int32; var intensity: Float }
        var pass = ComputePass(kernel: "prism_lut", uniforms: Uniforms(size: Int32(lut.size), intensity: intensity), isIdentity: intensity == 0)
        pass.lut = lut
        return OperationPlan(passes: [pass])
    }
}
