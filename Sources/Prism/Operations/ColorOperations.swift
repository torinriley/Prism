// ColorOperations.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation

/// A pass for a per-pixel operation: its standalone kernel, plus the description fusion needs.
private func pointwisePass<Uniforms: BitwiseCopyable>(
    kernel: String, uniforms: Uniforms, op: PointwiseOp, isIdentity: Bool
) -> ComputePass {
    var pass = ComputePass(kernel: kernel, uniforms: uniforms, isIdentity: isIdentity)
    pass.pointwise = op
    return pass
}

/// Scales scene-linear light by 2^`stops`. `Exposure(0)` is the identity.
///
/// Applied to straight (unpremultiplied) color after sRGB → linear decoding, then
/// re-encoded. Result is clamped to [0, 1].
public struct Exposure: ImageOperation {
    /// Exposure value in stops. Valid range: -10...10.
    public var stops: Float
    public init(_ stops: Float) { self.stops = stops }
    public var name: String { "Exposure" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(stops, in: -10...10, operation: name, parameter: "stops")
        struct Uniforms { var gain: Float }
        let gain = exp2(stops)
        return OperationPlan(passes: [pointwisePass(
            kernel: "prism_exposure", uniforms: Uniforms(gain: gain),
            op: PointwiseOp(code: .exposure, a: gain, name: name), isIdentity: stops == 0)])
    }
}

/// Scales the distance of each channel from mid-grey (0.5) in sRGB-encoded space.
/// `Contrast(1)` is the identity.
public struct Contrast: ImageOperation {
    /// Multiplier. Valid range: 0...4. 0 flattens to mid-grey.
    public var factor: Float
    public init(_ factor: Float) { self.factor = factor }
    public var name: String { "Contrast" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(factor, in: 0...4, operation: name, parameter: "factor")
        struct Uniforms { var factor: Float }
        return OperationPlan(passes: [pointwisePass(
            kernel: "prism_contrast", uniforms: Uniforms(factor: factor),
            op: PointwiseOp(code: .contrast, a: factor, name: name), isIdentity: factor == 1)])
    }
}

/// Scales each pixel's distance from its Rec. 709 luma, computed on sRGB-encoded values.
/// `Saturation(1)` is the identity; `Saturation(0)` is greyscale.
public struct Saturation: ImageOperation {
    /// Multiplier. Valid range: 0...4.
    public var factor: Float
    public init(_ factor: Float) { self.factor = factor }
    public var name: String { "Saturation" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(factor, in: 0...4, operation: name, parameter: "factor")
        struct Uniforms { var factor: Float }
        return OperationPlan(passes: [pointwisePass(
            kernel: "prism_saturation", uniforms: Uniforms(factor: factor),
            op: PointwiseOp(code: .saturation, a: factor, name: name), isIdentity: factor == 1)])
    }
}

/// A warm/cool color shift. Positive values warm (more red, less blue), negative cool.
///
/// This is an artistic control, **not** a Kelvin white-point adaptation: it applies
/// gains of 2^(±0.4·shift) to the red and blue channels in linear light and leaves green
/// unchanged. `Temperature(0)` is the identity.
public struct Temperature: ImageOperation {
    /// Valid range: -1...1.
    public var shift: Float
    public init(_ shift: Float) { self.shift = shift }
    public var name: String { "Temperature" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(shift, in: -1...1, operation: name, parameter: "shift")
        struct Uniforms { var redGain: Float; var blueGain: Float }
        let red = exp2(0.4 * shift), blue = exp2(-0.4 * shift)
        return OperationPlan(passes: [pointwisePass(
            kernel: "prism_temperature", uniforms: Uniforms(redGain: red, blueGain: blue),
            op: PointwiseOp(code: .temperature, a: red, b: blue, name: name), isIdentity: shift == 0)])
    }
}
