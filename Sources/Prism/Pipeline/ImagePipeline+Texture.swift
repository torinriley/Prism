// ImagePipeline+Texture.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal

/// A rendered texture and what it took to produce it.
public struct TextureRenderResult {
    public var texture: any MTLTexture
    public var metrics: RenderMetrics
}

extension ImagePipeline {
    /// Renders an existing `MTLTexture` through the pipeline without leaving the GPU.
    ///
    /// No CPU readback or copy takes place: the pipeline reads `input` directly, and the last
    /// pass writes straight into the result.
    ///
    /// - Parameters:
    ///   - input: A 2D, single-sample `rgba8Unorm`, `bgra8Unorm` or `rgba16Float` texture with `.shaderRead`
    ///     usage, created on the renderer's GPU. Its contents are interpreted as
    ///     **premultiplied alpha, sRGB-encoded** color; Prism does not convert (see COLOR.md).
    ///     It is only read, never modified. The pipeline runs in the texture's own format, so a
    ///     `rgba16Float` input is processed at ``Precision/high``.
    ///   - destination: Where to write the result. Must match the pipeline's output exactly
    ///     (size, pixel format) and have `.shaderRead` and `.shaderWrite` usage; it must not be
    ///     `input`. Pass one to reuse a texture across frames. If `nil`, a new texture of the
    ///     right size and format is allocated and returned.
    ///   - renderer: The renderer to use. Defaults to a shared process-wide one.
    /// - Returns: The output texture: `destination` if you gave one, otherwise a new texture you own.
    /// - Throws: `PrismError.unsupportedImage` for an unusable input,
    ///   `PrismError.incompatibleResources` for an unusable destination, plus the errors of the `CGImage`
    ///   overload of `render`.
    ///
    /// **Synchronization.** Prism uses its own command queue. Any GPU work that produces
    /// `input` must have *completed* before you call this (for example, await its command
    /// buffer's completion), and nothing may write `input` or `destination` until this call
    /// returns. When it returns, the result is ready to use on any queue.
    ///
    /// **Isolation.** `MTLTexture` is not `Sendable`, so these methods run on the caller's executor
    /// (`nonisolated(nonsending)`): you can call them from the main actor with your own textures. The
    /// CPU work they do is small (graph construction and command encoding); the GPU work is awaited
    /// without blocking.
    ///
    /// **Cancellation and failure.** As with the `CGImage` overload, cancellation takes effect
    /// only before the command buffer is committed. If the call throws, the contents of a
    /// caller-supplied `destination` are undefined.
    nonisolated(nonsending) public func render(
        _ input: any MTLTexture, into destination: (any MTLTexture)? = nil, using renderer: Renderer? = nil
    ) async throws -> any MTLTexture {
        try await renderWithMetrics(input, into: destination, using: renderer).texture
    }

    /// Like ``render(_:into:using:)``, also returning what happened. Texture renders report no
    /// import or export time, and their texture counts exclude `input`.
    nonisolated(nonsending) public func renderWithMetrics(
        _ input: any MTLTexture, into destination: (any MTLTexture)? = nil, using renderer: Renderer? = nil
    ) async throws -> TextureRenderResult {
        let renderer = try renderer ?? Renderer.shared()
        let (texture, metrics) = try await renderer.renderTexture(operations, input: input, destination: destination)
        return TextureRenderResult(texture: texture, metrics: metrics)
    }
}
