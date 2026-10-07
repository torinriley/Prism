// ImageOperation.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

/// Pixel dimensions of an image.
public struct ImageSize: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A single image-processing step.
///
/// Prism's operations are a closed set: `OperationPlan` can only be created inside the
/// module, so conforming types outside Prism cannot produce GPU work.
public protocol ImageOperation: Sendable {
    /// Human-readable name used in diagnostics.
    var name: String { get }

    /// Validates parameters and describes the GPU work for an image of `inputSize`.
    /// An empty plan means the operation is a mathematical no-op for these parameters.
    /// - Throws: `PrismError.invalidParameter` for out-of-range values.
    func plan(inputSize: ImageSize) throws -> OperationPlan
}

/// The GPU work an operation requires: a small graph of compute steps. Opaque to callers.
public struct OperationPlan: Sendable {
    enum Input: Sendable {
        /// The image entering the operation.
        case operationInput
        /// The output of an earlier step in this plan.
        case step(Int)
    }

    struct Step: Sendable {
        var name: String?
        var pass: ComputePass
        var inputs: [Input]
        /// `nil` means "same size as the operation's input".
        var outputSize: ImageSize?
    }

    /// Steps in dependency order. The last step's output is the operation's result.
    var steps: [Step]

    init(steps: [Step]) { self.steps = steps }

    /// A chain where each pass reads the previous one (the first reads the operation input).
    init(passes: [ComputePass]) {
        steps = passes.enumerated().map { index, pass in
            Step(name: nil, pass: pass, inputs: [index == 0 ? .operationInput : .step(index - 1)], outputSize: nil)
        }
    }

    /// An operation with nothing to do.
    static let identity = OperationPlan(steps: [])
}

func requireFinite(_ value: Float, in range: ClosedRange<Float>, operation: String, parameter: String) throws {
    guard value.isFinite, range.contains(value) else {
        throw PrismError.invalidParameter(
            operation: operation, parameter: parameter,
            reason: "\(value) is outside \(range.lowerBound)...\(range.upperBound)")
    }
}
