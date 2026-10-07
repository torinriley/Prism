// PrismError.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation

/// Errors thrown by Prism.
///
/// Cases describe what went wrong and what a caller can do about it. They deliberately
/// do not expose Metal object types.
public enum PrismError: Error, Sendable, Equatable {
    /// No Metal-capable GPU is available on this machine.
    case metalUnavailable
    /// Prism's compiled shader library could not be found or loaded.
    case shaderLibraryUnavailable(reason: String)
    /// A kernel expected by an operation is missing from the shader library.
    case shaderFunctionNotFound(name: String)
    /// A compute pipeline could not be created for a kernel.
    case pipelineCreationFailed(kernel: String, reason: String)
    /// An operation was configured with a value outside its supported range.
    case invalidParameter(operation: String, parameter: String, reason: String)
    /// The render graph is malformed (cycle, dangling reference, missing output, ...).
    case invalidGraph(reason: String)
    /// Resources connected in the graph have incompatible sizes or formats.
    case incompatibleResources(reason: String)
    /// A LUT file or table could not be parsed or is not supported.
    case invalidLUT(reason: String)
    /// The image's size, pixel layout, or color space cannot be processed.
    case unsupportedImage(reason: String)
    /// A GPU texture could not be allocated (usually: dimensions too large).
    case textureAllocationFailed(width: Int, height: Int)
    /// The GPU reported a failure while executing a submitted command buffer.
    case commandBufferFailed(reason: String)
}

extension PrismError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "No Metal-capable GPU is available."
        case .shaderLibraryUnavailable(let reason):
            "Prism's shader library could not be loaded: \(reason)"
        case .shaderFunctionNotFound(let name):
            "Shader function '\(name)' was not found in Prism's shader library."
        case .pipelineCreationFailed(let kernel, let reason):
            "Failed to create a compute pipeline for '\(kernel)': \(reason)"
        case .invalidParameter(let op, let parameter, let reason):
            "\(op): invalid '\(parameter)': \(reason)"
        case .invalidGraph(let reason):
            "Invalid render graph: \(reason)"
        case .incompatibleResources(let reason):
            "Incompatible resources: \(reason)"
        case .invalidLUT(let reason):
            "Invalid LUT: \(reason)"
        case .unsupportedImage(let reason):
            "Unsupported image: \(reason)"
        case .textureAllocationFailed(let w, let h):
            "Could not allocate a \(w)×\(h) GPU texture."
        case .commandBufferFailed(let reason):
            "GPU command execution failed: \(reason)"
        }
    }
}
