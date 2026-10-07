// SpatialOperations.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation

/// Normalized 1D Gaussian weights for standard deviation `sigma` (in pixels).
///
/// The kernel spans ±ceil(3σ) taps (≥ 1): beyond 3σ the Gaussian holds < 0.27% of its
/// mass, which is below one 8-bit level, and the weights are renormalized to sum to 1.
func gaussianKernel(sigma: Float) -> (radius: Int, weights: [Float]) {
    if sigma == 0 { return (0, [1]) }
    let radius = max(1, Int((3 * Double(sigma)).rounded(.up)))
    var weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * Double(sigma) * Double(sigma))) }
    let sum = weights.reduce(0, +)
    weights = weights.map { $0 / sum }
    return (radius, weights.map(Float.init))
}

/// Largest kernel radius (taps each side) that uses the threadgroup-tiled kernels: the largest
/// radius a `GaussianBlur` can have (σ = 64 → 192 taps). Measured at 4K, tiling beat the direct
/// kernels at every radius, including this one (σ=64: 40.9 vs 52.4 ms). The direct kernels remain
/// in the shader library as the reference the tiled ones are tested against.
let maxTiledBlurRadius = 192

private func blurPass(horizontal: Bool, uniforms: some BitwiseCopyable, weights: [Float], radius: Int, isIdentity: Bool) -> ComputePass {
    let tiled = radius > 0 && radius <= maxTiledBlurRadius
    let kernel = (horizontal ? "prism_blur_horizontal" : "prism_blur_vertical") + (tiled ? "_tiled" : "")
    // Tiled kernels read taps through three zeros of padding on each side (see Blur.metal).
    let constants = tiled ? [0, 0, 0] + weights + [0, 0, 0] : weights
    var pass = ComputePass(kernel: kernel, uniforms: uniforms, constants: constants, isIdentity: isIdentity)
    if tiled { pass.tiling = horizontal ? .horizontal(radius: radius) : .vertical(radius: radius) }
    return pass
}

/// The two plan steps of a separable Gaussian blur, reading the operation's input.
private func gaussianSteps(sigma: Float, name: String, isIdentity: Bool = false) -> [OperationPlan.Step] {
    struct Uniforms { var radius: Int32 }
    let (radius, weights) = gaussianKernel(sigma: sigma)
    let uniforms = Uniforms(radius: Int32(radius))
    return [
        .init(name: "\(name) horizontal",
              pass: blurPass(horizontal: true, uniforms: uniforms, weights: weights, radius: radius, isIdentity: isIdentity),
              inputs: [.operationInput], outputSize: nil),
        .init(name: "\(name) vertical",
              pass: blurPass(horizontal: false, uniforms: uniforms, weights: weights, radius: radius, isIdentity: isIdentity),
              inputs: [.step(0)], outputSize: nil),
    ]
}

/// Gaussian blur, implemented as two separable 1D passes (horizontal, then vertical).
///
/// A 2D Gaussian is the product of two 1D Gaussians, so blurring each axis in turn costs
/// 2·(2r+1) taps per pixel instead of (2r+1)². Edges clamp to the border texel.
/// `GaussianBlur(radius: 0)` is a no-op. The blur operates on stored values
/// (premultiplied, sRGB-encoded), not on linear light.
public struct GaussianBlur: ImageOperation {
    /// Standard deviation in pixels. Valid range: 0...64.
    public var radius: Float
    public init(radius: Float) { self.radius = radius }
    public var name: String { "GaussianBlur" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(radius, in: 0...64, operation: name, parameter: "radius")
        return OperationPlan(steps: gaussianSteps(sigma: radius, name: name, isIdentity: radius == 0))
    }
}

/// Unsharp-mask sharpening: `original + amount · (original − blurred)`.
///
/// The blur is a Gaussian of standard deviation `radius`. `Sharpen(amount: 0)` is a no-op.
public struct Sharpen: ImageOperation {
    /// Strength. Valid range: 0...5.
    public var amount: Float
    /// Blur standard deviation in pixels. Valid range: 0.1...64.
    public var radius: Float
    public init(amount: Float, radius: Float = 1) {
        self.amount = amount
        self.radius = radius
    }
    public var name: String { "Sharpen" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        try requireFinite(amount, in: 0...5, operation: name, parameter: "amount")
        try requireFinite(radius, in: 0.1...64, operation: name, parameter: "radius")
        struct Uniforms { var amount: Float }
        var steps = gaussianSteps(sigma: radius, name: "\(name) blur")
        steps.append(.init(
            name: "\(name) combine",
            // With amount 0 only the combine step is the identity; the blur steps it leaves
            // unread are then removed as dead nodes.
            pass: ComputePass(kernel: "prism_unsharp_combine", uniforms: Uniforms(amount: amount), isIdentity: amount == 0),
            inputs: [.operationInput, .step(1)], outputSize: nil))
        return OperationPlan(steps: steps)
    }
}

/// Resamples the image to a new size.
///
/// Sampling is bilinear with pixel-center alignment and clamped borders. Bilinear does
/// not prefilter, so downscaling by more than ~2× aliases; higher-quality methods can be
/// added as further `Method` cases without changing call sites.
public struct Resize: ImageOperation {
    public enum Method: Sendable, Equatable {
        case bilinear
    }

    enum Target: Sendable, Equatable {
        case size(width: Int, height: Int)
        case scale(Float)
    }

    static let maxDimension = 16384

    let target: Target
    public var method: Method

    /// Resizes to an exact size. Each dimension must be in 1...16384.
    public init(width: Int, height: Int, method: Method = .bilinear) {
        target = .size(width: width, height: height)
        self.method = method
    }

    /// Scales both dimensions by `scale` (> 0), rounding to the nearest pixel (minimum 1).
    public init(scale: Float, method: Method = .bilinear) {
        target = .scale(scale)
        self.method = method
    }

    public var name: String { "Resize" }

    public func plan(inputSize: ImageSize) throws -> OperationPlan {
        let output: ImageSize
        switch target {
        case .size(let width, let height):
            output = ImageSize(width: width, height: height)
        case .scale(let scale):
            guard scale.isFinite, scale > 0 else {
                throw PrismError.invalidParameter(operation: name, parameter: "scale", reason: "\(scale) must be finite and > 0")
            }
            output = ImageSize(
                width: max(1, Int((Double(inputSize.width) * Double(scale)).rounded())),
                height: max(1, Int((Double(inputSize.height) * Double(scale)).rounded())))
        }
        for (label, value) in [("width", output.width), ("height", output.height)] where !(1...Self.maxDimension).contains(value) {
            throw PrismError.invalidParameter(
                operation: name, parameter: label, reason: "\(value) is outside 1...\(Self.maxDimension)")
        }

        struct Uniforms { var scaleX: Float; var scaleY: Float }
        let uniforms = Uniforms(
            scaleX: Float(Double(inputSize.width) / Double(output.width)),
            scaleY: Float(Double(inputSize.height) / Double(output.height)))
        var pass = ComputePass(kernel: "prism_resize_bilinear", uniforms: uniforms, isIdentity: output == inputSize)
        pass.inputsMatchOutputSize = false
        return OperationPlan(steps: [.init(name: nil, pass: pass, inputs: [.operationInput], outputSize: output)])
    }
}
