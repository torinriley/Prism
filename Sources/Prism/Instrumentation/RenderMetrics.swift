// RenderMetrics.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation

/// How much a ``Renderer`` measures.
public enum InstrumentationLevel: Sendable, Comparable {
    /// Counters and total wall-clock time only. No signposts, no GPU or encode timing.
    case off
    /// Default. Adds CPU encode time, GPU time (from the command buffer), and signposts for
    /// Instruments. Costs a few clock reads per render.
    case standard
    /// Adds per-operation GPU timings. This encodes each operation in its own compute
    /// encoder so the GPU can timestamp it, which is *not* how `.standard` encodes the
    /// work, so total GPU time can differ slightly. Use for inspection, not for benchmarks of
    /// the default path.
    case detailed
}

/// What happened during one render. All durations are in seconds.
public struct RenderMetrics: Sendable {
    public var level: InstrumentationLevel
    public var inputSize: ImageSize
    public var outputSize: ImageSize

    // MARK: Time

    /// Wall-clock time of the whole `render` call, including image import/export.
    public var totalDuration: TimeInterval
    /// Time converting the input `CGImage` into a GPU texture. `nil` at `.off`.
    public var importDuration: TimeInterval?
    /// CPU time spent building the command buffer (planning, pipeline lookup, encoding). `nil` at `.off`.
    public var cpuEncodeDuration: TimeInterval?
    /// Time the GPU spent executing the command buffer, as reported by Metal. `nil` at `.off`.
    public var gpuDuration: TimeInterval?
    /// Time converting the output texture to a `CGImage`. `nil` at `.off`.
    public var exportDuration: TimeInterval?

    /// One entry per GPU pass in execution order. `gpuDuration` is populated only at
    /// `.detailed` (and only on hardware that supports timestamp counters).
    public var nodes: [NodeMetrics]

    // MARK: Resources (this render only)

    /// Textures newly created by the device for this render.
    public var textureAllocations: Int
    /// Textures taken from the pool instead.
    public var textureReuses: Int
    /// Textures live at once during this render: the input plus the recycled intermediates.
    public var peakActiveTextures: Int
    /// Textures a one-per-pass scheme would have needed (input + every pass output).
    public var logicalTextures: Int
    /// Device-reported size of this render's textures.
    public var peakTextureBytes: Int

    // MARK: Pipeline cache (this render only)

    public var pipelineCacheHits: Int
    /// Pipelines compiled during this render (cache misses).
    public var pipelineCacheMisses: Int

    // MARK: Optimization

    /// Passes the graph optimizer removed before execution (identity and dead passes).
    public var eliminatedPasses: Int
}

/// Timing of one GPU pass.
public struct NodeMetrics: Sendable {
    public var name: String
    public var outputSize: ImageSize
    /// `nil` unless the renderer ran at `.detailed` on a GPU that supports timestamps.
    public var gpuDuration: TimeInterval?
}

/// The output of ``ImagePipeline/renderWithMetrics(_:using:)``.
public struct RenderResult: Sendable {
    public var image: CGImage
    public var metrics: RenderMetrics
}

/// Lifetime totals for a ``Renderer``.
public struct RendererStatistics: Sendable, Equatable {
    public var pipelineCacheHits: Int
    public var pipelineCacheMisses: Int
    public var cachedPipelines: Int
    public var textureAllocations: Int
    public var textureReuses: Int
    public var activeTextures: Int
    public var peakActiveTextures: Int
    public var pooledTextures: Int
    public var textureEvictions: Int
    public var residentTextureBytes: Int
    public var peakResidentTextureBytes: Int
    /// LUT textures built and uploaded (once per distinct `LUT3D` while it stays cached).
    public var lutTextureUploads: Int
    /// Renders that found their LUT texture already cached.
    public var lutTextureHits: Int
    /// Device memory held by cached LUT textures.
    public var cachedLUTBytes: Int
}

extension RenderMetrics: CustomStringConvertible {
    public var description: String {
        func ms(_ t: TimeInterval?) -> String { t.map { String(format: "%.3f ms", $0 * 1000) } ?? "—" }
        var lines = [
            "FRAME  \(inputSize.width)×\(inputSize.height) → \(outputSize.width)×\(outputSize.height)  [\(level)]",
            "  total   \(ms(totalDuration))",
            "  import  \(ms(importDuration))",
            "  encode  \(ms(cpuEncodeDuration))",
            "  gpu     \(ms(gpuDuration))",
            "  export  \(ms(exportDuration))",
            "GRAPH" + (eliminatedPasses > 0 ? "  (\(eliminatedPasses) passes eliminated)" : ""),
        ]
        lines += nodes.map { "  \($0.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(ms($0.gpuDuration))" }
        lines += [
            "RESOURCES  \(peakActiveTextures) active (of \(logicalTextures) logical), "
                + "\(textureAllocations) allocated, \(textureReuses) reused, \(peakTextureBytes / 1024) KiB",
            "PIPELINES  \(pipelineCacheHits) hits, \(pipelineCacheMisses) compiled",
        ]
        return lines.joined(separator: "\n")
    }
}
