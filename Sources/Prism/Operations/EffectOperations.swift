// EffectOperations.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// Darkens toward the corners of the frame.
///
/// Scales scene-linear light by `1 − amount · smoothstep(radius, 1, d)`, where `d` is the
/// distance from the center, normalized so the corners are at 1. The falloff follows the
/// frame (elliptical on non-square images). `Vignette(amount: 0)` is the identity.
public struct Vignette: ImageOperation {
    /// Darkening at the corners. Valid range: 0...1 (1 reaches black at the corners).
    public var amount: Float
    /// Normalized distance where the falloff begins. Valid range: 0...0.95.
    public var radius: Float
    public init(amount: Float, radius: Float = 0.5) {
        self.amount = amount
        self.radius = radius
    }
    public var name: String { "Vignette" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(amount, in: 0...1, operation: name, parameter: "amount")
        try requireFinite(radius, in: 0...0.95, operation: name, parameter: "radius")
        struct Uniforms { var amount: Float; var radius: Float }
        var pass = ComputePass(kernel: "prism_vignette", uniforms: Uniforms(amount: amount, radius: radius), isIdentity: amount == 0)
        pass.pointwise = PointwiseOp(code: .vignette, a: amount, b: radius, name: name)
        return OperationPlan(passes: [pass])
    }
}
