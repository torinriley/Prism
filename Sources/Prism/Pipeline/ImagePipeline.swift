// ImagePipeline.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics

/// An ordered list of operations applied to an image.
///
/// ```swift
/// let pipeline = ImagePipeline {
///     Exposure(0.4)
///     Contrast(1.15)
/// }
/// let result = try await pipeline.render(image)
/// ```
///
/// Pipelines are values: cheap to copy, safe to share, reusable across renders.
public struct ImagePipeline: Sendable {
    public private(set) var operations: [any ImageOperation]

    public init(operations: [any ImageOperation] = []) {
        self.operations = operations
    }

    public init(@OperationBuilder _ content: () -> [any ImageOperation]) {
        self.operations = content()
    }

    /// Renders `image` through the pipeline on the GPU.
    ///
    /// - Parameters:
    ///   - precision: How values are stored while the pipeline runs; see ``Precision``. With
    ///     `.high` the returned image has 16-bit float components.
    ///   - renderer: The renderer to use. Defaults to a shared process-wide one.
    /// - Throws: `PrismError` for invalid parameters, unsupported images, or GPU failure;
    ///   `CancellationError` if the task is cancelled before the work is submitted.
    ///
    /// **Cancellation.** Cancelling the calling task stops encoding promptly and throws
    /// `CancellationError`, provided it happens before the command buffer is committed.
    /// Once committed, the GPU cannot be told to abandon the work: it runs to completion,
    /// the caller keeps waiting for it, and the result is returned normally. Cancellation
    /// never frees a resource the GPU is using, because Metal retains everything a command
    /// buffer touches until it completes.
    public func render(_ image: CGImage, precision: Precision = .standard, using renderer: Renderer? = nil) async throws -> CGImage {
        let renderer = try renderer ?? Renderer.shared()
        return try await renderer.render(operations, input: image, precision: precision)
    }

    /// Like ``render(_:using:)``, but also returns what happened: timings, texture and
    /// pipeline-cache behavior for this render. How much is measured is set by the
    /// renderer's ``InstrumentationLevel``.
    public func renderWithMetrics(_ image: CGImage, precision: Precision = .standard, using renderer: Renderer? = nil) async throws -> RenderResult {
        let renderer = try renderer ?? Renderer.shared()
        return try await renderer.renderWithMetrics(operations, input: image, precision: precision)
    }
}

/// Collects operations declared in an ``ImagePipeline`` body.
@resultBuilder
public enum OperationBuilder {
    public static func buildExpression(_ operation: some ImageOperation) -> [any ImageOperation] { [operation] }
    public static func buildBlock(_ parts: [any ImageOperation]...) -> [any ImageOperation] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [any ImageOperation]?) -> [any ImageOperation] { part ?? [] }
    public static func buildEither(first part: [any ImageOperation]) -> [any ImageOperation] { part }
    public static func buildEither(second part: [any ImageOperation]) -> [any ImageOperation] { part }
    public static func buildArray(_ parts: [[any ImageOperation]]) -> [any ImageOperation] { parts.flatMap { $0 } }
}
