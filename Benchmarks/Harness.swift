// Harness.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import Metal
import Prism

/// Result of benchmarking one pipeline on one image.
struct CaseResult: Codable {
    var suite: String
    var name: String
    var resolution: String
    var width: Int
    var height: Int
    var iterations: Int
    /// Whole `render` call, including CGImage import/export.
    var total: Summary
    var importTime: Summary
    /// CPU time building the command buffer.
    var encode: Summary
    /// GPU execution time reported by Metal.
    var gpu: Summary
    var export: Summary
    /// Textures created by the device per render (median render is warm, so usually 0).
    var textureAllocationsPerRender: Int
    var peakTextureMiB: Double
    var passes: Int
    var cacheMissesFirstRender: Int?

    /// Megapixels per second of end-to-end `render` (median).
    var endToEndMPixPerSec: Double { Double(width * height) / 1e6 / total.median }
    /// Megapixels per second of encode + GPU only (median), excluding CGImage conversion.
    var engineMPixPerSec: Double? {
        let time = encode.median + gpu.median
        return time > 0 ? Double(width * height) / 1e6 / time : nil   // nil when instrumentation is off
    }
}

struct Settings {
    var iterations = 30
    var warmup = 5
}

/// Runs `pipeline` repeatedly on `renderer` and summarizes per-stage timings.
/// The warm-up renders absorb pipeline compilation and texture allocation, so the summary
/// reflects steady state; use ``coldRender`` for first-render cost.
func measure(
    suite: String, name: String, pipeline: ImagePipeline, image: CGImage, resolution: Resolution,
    renderer: Renderer, settings: Settings, precision: Precision = .standard
) async throws -> CaseResult {
    var first: RenderMetrics?
    for i in 0..<settings.warmup {
        let m = try await pipeline.renderWithMetrics(image, precision: precision, using: renderer).metrics
        if i == 0 { first = m }
    }
    var total: [Double] = [], imp: [Double] = [], enc: [Double] = [], gpu: [Double] = [], exp: [Double] = []
    var last: RenderMetrics!
    for _ in 0..<settings.iterations {
        let m = try await pipeline.renderWithMetrics(image, precision: precision, using: renderer).metrics
        total.append(m.totalDuration); imp.append(m.importDuration ?? 0); enc.append(m.cpuEncodeDuration ?? 0)
        gpu.append(m.gpuDuration ?? 0); exp.append(m.exportDuration ?? 0)
        last = m
    }
    return CaseResult(
        suite: suite, name: name, resolution: resolution.name, width: image.width, height: image.height,
        iterations: settings.iterations,
        total: Summary(total), importTime: Summary(imp), encode: Summary(enc), gpu: Summary(gpu), export: Summary(exp),
        textureAllocationsPerRender: last.textureAllocations,
        peakTextureMiB: Double(last.peakTextureBytes) / 1_048_576,
        passes: last.nodes.count,
        cacheMissesFirstRender: first?.pipelineCacheMisses)
}

/// Builds an `rgba8Unorm` texture holding `image` (premultiplied sRGB), as a client with its own
/// Metal content would. Public API only; uses the system default device, which `Renderer` also uses.
func makeTexture(from image: CGImage) -> any MTLTexture {
    let device = MTLCreateSystemDefaultDevice()!
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
    let texture = device.makeTexture(descriptor: desc)!
    let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                    withBytes: context.data!, bytesPerRow: image.width * 4)
    return texture
}

/// Same as ``makeTexture(from:)`` but `rgba16Float` (extended sRGB, premultiplied), for the high-precision path.
func makeTexture16F(from image: CGImage) -> any MTLTexture {
    let device = MTLCreateSystemDefaultDevice()!
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: image.width, height: image.height, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
    let texture = device.makeTexture(descriptor: desc)!
    let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: image.width * 8,
        space: CGColorSpace(name: CGColorSpace.extendedSRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                    withBytes: context.data!, bytesPerRow: image.width * 8)
    return texture
}

/// Like ``measure`` but through the texture API: no `CGImage` import or export. The first render
/// allocates the output texture; every later render writes into it (the way a real-time client
/// reuses its frame buffer).
func measureTexture(
    suite: String, name: String, pipeline: ImagePipeline, input: any MTLTexture, resolution: Resolution,
    renderer: Renderer, settings: Settings
) async throws -> CaseResult {
    let first = try await pipeline.renderWithMetrics(input, using: renderer)
    let destination = first.texture
    for _ in 1..<max(settings.warmup, 1) { _ = try await pipeline.renderWithMetrics(input, into: destination, using: renderer) }
    var total: [Double] = [], enc: [Double] = [], gpu: [Double] = []
    var last = first.metrics
    for _ in 0..<settings.iterations {
        last = try await pipeline.renderWithMetrics(input, into: destination, using: renderer).metrics
        total.append(last.totalDuration); enc.append(last.cpuEncodeDuration ?? 0); gpu.append(last.gpuDuration ?? 0)
    }
    let zeros = Summary([Double](repeating: 0, count: settings.iterations))
    return CaseResult(
        suite: suite, name: name, resolution: resolution.name, width: input.width, height: input.height,
        iterations: settings.iterations, total: Summary(total), importTime: zeros, encode: Summary(enc), gpu: Summary(gpu), export: zeros,
        textureAllocationsPerRender: last.textureAllocations, peakTextureMiB: Double(last.peakTextureBytes) / 1_048_576,
        passes: last.nodes.count, cacheMissesFirstRender: first.metrics.pipelineCacheMisses)
}

func printHeader() {
    print("| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
}

func printRow(_ r: CaseResult) {
    print("| \(r.name) | \(r.resolution) | \(r.passes) | \(ms(r.total.median)) | \(r.importTime.median > 0 ? ms(r.importTime.median) : "—") | \(ms(r.encode.median)) | \(ms(r.gpu.median)) | \(r.export.median > 0 ? ms(r.export.median) : "—") | \(r.engineMPixPerSec.map { String(format: "%.0f", $0) } ?? "—") | \(String(format: "%.0f", r.endToEndMPixPerSec)) |")
}
