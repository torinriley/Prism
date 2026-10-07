// Suites.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import Prism

/// The operations measured individually. Each is a single pipeline stage.
func singleOperationCases(lutSize: Int) throws -> [(String, ImagePipeline)] {
    let lut = try LUT3D.identity(size: lutSize)
    return [
        ("Exposure", ImagePipeline { Exposure(0.4) }),
        ("Contrast", ImagePipeline { Contrast(1.15) }),
        ("Saturation", ImagePipeline { Saturation(1.2) }),
        ("Temperature", ImagePipeline { Temperature(0.3) }),
        ("GaussianBlur σ=2", ImagePipeline { GaussianBlur(radius: 2) }),
        ("GaussianBlur σ=8", ImagePipeline { GaussianBlur(radius: 8) }),
        ("GaussianBlur σ=32", ImagePipeline { GaussianBlur(radius: 32) }),
        ("Sharpen", ImagePipeline { Sharpen(amount: 0.5, radius: 1.5) }),
        ("Resize 0.5×", ImagePipeline { Resize(scale: 0.5) }),
        ("Vignette", ImagePipeline { Vignette(amount: 0.4) }),
        ("LUT \(lutSize)³", ImagePipeline { LUTGrade(lut) }),
    ]
}

/// Representative multi-stage pipelines.
func pipelineCases() throws -> [(String, ImagePipeline)] {
    let lut = try LUT3D.identity(size: 33)
    return [
        ("5-stage", ImagePipeline {
            Exposure(0.3); Contrast(1.1); Saturation(1.1); GaussianBlur(radius: 4); Vignette(amount: 0.3)
        }),
        ("10-stage", ImagePipeline {
            Exposure(0.3); Contrast(1.1); Saturation(1.1); Temperature(0.1); GaussianBlur(radius: 4)
            Sharpen(amount: 0.4); LUTGrade(lut); Vignette(amount: 0.3); Contrast(1.05); Exposure(-0.1)
        }),
        ("10 per-pixel", ImagePipeline {
            Exposure(0.3); Contrast(1.1); Saturation(1.1); Temperature(0.1); Exposure(-0.2)
            Contrast(1.05); Saturation(0.95); Temperature(-0.05); Exposure(0.1); Contrast(0.97)
        }),
    ]
}

func runSuites(
    _ suites: Set<String>, resolutions: [(Resolution, CGImage)], settings: Settings
) async throws -> [CaseResult] {
    var sink: [CaseResult] = []
    if suites.contains("ops") {
        print("\n## Single operations (warm renderer, \(settings.iterations) iterations, \(settings.warmup) warm-up)\n")
        printHeader()
        let renderer = try Renderer()
        for (res, image) in resolutions {
            for (name, pipeline) in try singleOperationCases(lutSize: 33) {
                let r = try await measure(suite: "ops", name: name, pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings)
                printRow(r); sink.append(r)
            }
        }
    }
    if suites.contains("pipelines") {
        print("\n## Multi-stage pipelines (warm renderer)\n")
        printHeader()
        let renderer = try Renderer()
        for (res, image) in resolutions {
            for (name, pipeline) in try pipelineCases() {
                let r = try await measure(suite: "pipelines", name: name, pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings)
                printRow(r); sink.append(r)
            }
        }
    }
    if suites.contains("cold") { try await coldSuite(resolutions: resolutions, sink: &sink) }
    if suites.contains("resources") { try await resourceSuite(resolutions: resolutions) }
    if suites.contains("precision") { try await precisionSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("blur") { try await blurSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("texture") { try await textureSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("alu") { try await aluSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("fusion") { try await fusionSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("optimizer") { try await optimizerSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    if suites.contains("instrumentation") { try await instrumentationSuite(resolutions: resolutions, settings: settings, sink: &sink) }
    return sink
}

/// Cold versus warm: a brand-new `Renderer` (library load, pipeline compilation, texture
/// allocation) against the same render on a warmed one. Repeated on fresh renderers so the
/// cold number is a distribution, not one sample. Note: the OS caches compiled shader
/// binaries across processes, so "cold" here means cold *for this process's Renderer*.
func coldSuite(resolutions: [(Resolution, CGImage)], sink: inout [CaseResult]) async throws {
    print("\n## Cold vs warm (fresh `Renderer` per cold sample, 15 samples)\n")
    print("| pipeline | res | renderer init ms | cold render ms | cold gpu | cold encode | pipelines compiled | allocations | warm render ms | warm gpu | warm encode |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (res, image) in resolutions {
        for (name, pipeline) in try pipelineCases().prefix(2) {
            var inits: [Double] = [], cold: [Double] = [], coldGPU: [Double] = [], coldEnc: [Double] = []
            var warm: [Double] = [], warmGPU: [Double] = [], warmEnc: [Double] = []
            var compiled = 0, allocations = 0
            for _ in 0..<15 {
                let clock = ContinuousClock()
                let t0 = clock.now
                let renderer = try Renderer()
                inits.append((clock.now - t0).seconds)
                let c = try await pipeline.renderWithMetrics(image, using: renderer).metrics
                cold.append(c.totalDuration); coldGPU.append(c.gpuDuration ?? 0); coldEnc.append(c.cpuEncodeDuration ?? 0)
                compiled = c.pipelineCacheMisses; allocations = c.textureAllocations
                for _ in 0..<2 { _ = try await pipeline.renderWithMetrics(image, using: renderer) }
                let w = try await pipeline.renderWithMetrics(image, using: renderer).metrics
                warm.append(w.totalDuration); warmGPU.append(w.gpuDuration ?? 0); warmEnc.append(w.cpuEncodeDuration ?? 0)
            }
            print("| \(name) | \(res.name) | \(ms(Summary(inits).median)) | \(ms(Summary(cold).median)) | \(ms(Summary(coldGPU).median)) | \(ms(Summary(coldEnc).median)) | \(compiled) | \(allocations) | \(ms(Summary(warm).median)) | \(ms(Summary(warmGPU).median)) | \(ms(Summary(warmEnc).median)) |")
        }
    }
}

/// Texture allocation behavior: allocations, reuse and memory on first vs later renders.
func resourceSuite(resolutions: [(Resolution, CGImage)]) async throws {
    print("\n## Texture allocation behavior\n")
    print("| pipeline | res | passes | live textures | logical | render 1 allocs | render 2 allocs | render 2 reuses | peak texture MiB | resident after MiB |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for (res, image) in resolutions {
        for (name, pipeline) in try pipelineCases() {
            let renderer = try Renderer()
            let a = try await pipeline.renderWithMetrics(image, using: renderer).metrics
            let b = try await pipeline.renderWithMetrics(image, using: renderer).metrics
            let s = renderer.statistics
            print("| \(name) | \(res.name) | \(a.nodes.count) | \(a.peakActiveTextures) | \(a.logicalTextures) | \(a.textureAllocations) | \(b.textureAllocations) | \(b.textureReuses) | \(String(format: "%.1f", Double(a.peakTextureBytes) / 1_048_576)) | \(String(format: "%.1f", Double(s.residentTextureBytes) / 1_048_576)) |")
        }
    }
}

/// What instrumentation costs: the same pipeline at each level.
func instrumentationSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Instrumentation overhead (5-stage pipeline)\n")
    printHeader()
    let pipeline = try pipelineCases()[0].1
    for (res, image) in resolutions {
        for level in [InstrumentationLevel.off, .standard, .detailed] {
            let renderer = try Renderer(instrumentation: level)
            let r = try await measure(suite: "instrumentation", name: "5-stage @\(level)", pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings)
            printRow(r); sink.append(r)
        }
    }
}

/// Optimizer on vs off. The pipelines model an editing UI whose controls sit at neutral
/// defaults: every stage is present, but most (or all) are mathematically no-ops.
func optimizerSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Graph optimizer: off vs on\n")
    printHeader()
    let cases: [(String, ImagePipeline)] = [
        ("6 neutral stages", ImagePipeline {
            Exposure(0); Contrast(1); Saturation(1); GaussianBlur(radius: 0); Sharpen(amount: 0); Vignette(amount: 0)
        }),
        ("1 active + 5 neutral", ImagePipeline {
            Exposure(0.3); Contrast(1); Saturation(1); GaussianBlur(radius: 0); Sharpen(amount: 0); Vignette(amount: 0)
        }),
        ("blur + 5 neutral", ImagePipeline {
            Exposure(0); Contrast(1); Saturation(1); GaussianBlur(radius: 8); Sharpen(amount: 0); Vignette(amount: 0)
        }),
    ]
    for (res, image) in resolutions {
        for (name, pipeline) in cases {
            for (label, options) in [("off", OptimizationOptions.none), ("on", .all)] {
                let renderer = try Renderer(optimizations: options)
                let r = try await measure(suite: "optimizer", name: "\(name) [opt \(label)]", pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings)
                printRow(r); sink.append(r)
            }
        }
    }
}

/// Fusion off vs on, for chains of per-pixel operations of increasing length, plus a chain
/// split by a blur. "off" keeps identity and dead-node elimination so only fusion differs.
func fusionSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Per-pixel fusion: off vs on\n")
    printHeader()
    let cases: [(String, ImagePipeline)] = [
        ("2 per-pixel", ImagePipeline { Exposure(0.3); Contrast(1.1) }),
        ("3 per-pixel", ImagePipeline { Exposure(0.3); Contrast(1.1); Saturation(1.1) }),
        ("5 per-pixel", ImagePipeline { Exposure(0.3); Contrast(1.1); Saturation(1.1); Temperature(0.1); Vignette(amount: 0.3) }),
        ("10 per-pixel", ImagePipeline {
            Exposure(0.3); Contrast(1.1); Saturation(1.1); Temperature(0.1); Exposure(-0.2)
            Contrast(1.05); Saturation(0.95); Temperature(-0.05); Exposure(0.1); Contrast(0.97)
        }),
        ("3 + blur σ=4 + 3", ImagePipeline {
            Exposure(0.3); Contrast(1.1); Saturation(1.1); GaussianBlur(radius: 4); Temperature(0.1); Vignette(amount: 0.3); Exposure(-0.1)
        }),
    ]
    for (res, image) in resolutions {
        for (name, pipeline) in cases {
            for (label, options) in [("off", OptimizationOptions([.identityElimination, .deadNodeElimination])), ("on", .all)] {
                let renderer = try Renderer(optimizations: options)
                let r = try await measure(suite: "fusion", name: "\(name) [fusion \(label)]", pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings)
                printRow(r); sink.append(r)
            }
        }
    }
}

/// Is a per-pixel chain limited by memory traffic or by arithmetic? Chains of N identical
/// operations, fusion off vs on. Contrast and Saturation have no transcendental functions;
/// Exposure and Temperature each evaluate six `pow`s per pixel (sRGB decode + encode).
/// If time scales with N for the pow-heavy operations but stays near the one-pass floor for
/// the cheap ones, the bottleneck is arithmetic, not bandwidth.
func aluSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Memory vs arithmetic: N identical per-pixel operations\n")
    printHeader()
    func chain(_ n: Int, _ make: @escaping (Int) -> any ImageOperation) -> ImagePipeline {
        ImagePipeline(operations: (0..<n).map(make))
    }
    // Parameters alternate slightly so no stage is neutral (identity elimination would remove it).
    let kinds: [(String, (Int) -> any ImageOperation)] = [
        ("Contrast", { Contrast($0 % 2 == 0 ? 1.05 : 0.95) }),
        ("Saturation", { Saturation($0 % 2 == 0 ? 1.05 : 0.95) }),
        ("Exposure", { Exposure($0 % 2 == 0 ? 0.05 : -0.05) }),
        ("Temperature", { Temperature($0 % 2 == 0 ? 0.05 : -0.05) }),
    ]
    for (res, image) in resolutions {
        for (kind, make) in kinds {
            for n in [1, 2, 5, 10, 20, 40] {
                for (label, options) in [("off", OptimizationOptions([.identityElimination, .deadNodeElimination])), ("on", .all)] where !(n == 1 && label == "on") {
                    let renderer = try Renderer(optimizations: options)
                    let r = try await measure(suite: "alu", name: "\(n)× \(kind) [fusion \(label)]", pipeline: chain(n, make), image: image, resolution: res, renderer: renderer, settings: settings)
                    printRow(r); sink.append(r)
                }
            }
        }
    }
}

/// The `MTLTexture` path: the input is already a texture and the output stays one, so there is no
/// `CGImage` conversion. `total` here is encode + GPU wait + bookkeeping: what a real-time
/// client holding its own textures would see.
func textureSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Texture in / texture out (warm renderer, destination reused)\n")
    printHeader()
    let renderer = try Renderer()
    var cases = try singleOperationCases(lutSize: 33).filter { ["Exposure", "Contrast", "GaussianBlur σ=8", "Sharpen", "LUT 33³"].contains($0.0) }
    cases += try pipelineCases()
    for (res, image) in resolutions {
        let texture = makeTexture(from: image)
        for (name, pipeline) in cases {
            let r = try await measureTexture(suite: "texture", name: "\(name) [texture]", pipeline: pipeline, input: texture, resolution: res, renderer: renderer, settings: settings)
            printRow(r); sink.append(r)
        }
    }
}

/// Gaussian blur on the texture path across radii: pure GPU cost, no conversions, GPU kept busy
/// by back-to-back renders. Reports GPU ms per megapixel so sizes are comparable.
func blurSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Gaussian blur, texture in/out\n")
    printHeader()
    let renderer = try Renderer()
    for (res, image) in resolutions {
        let texture = makeTexture(from: image)
        for sigma: Float in [1, 2, 4, 8, 16, 32, 64] {
            let pipeline = ImagePipeline { GaussianBlur(radius: sigma) }
            let r = try await measureTexture(suite: "blur", name: "GaussianBlur σ=\(Int(sigma)) [texture]", pipeline: pipeline, input: texture, resolution: res, renderer: renderer, settings: settings)
            printRow(r); sink.append(r)
        }
    }
}

/// What 16-bit float storage costs: the same pipelines with `rgba8Unorm` and `rgba16Float`
/// storage, on the texture path (pure GPU + memory traffic) and the `CGImage` path (which also
/// pays for 64-bit-per-pixel import and export). Memory is the device-reported size of one render's textures.
func precisionSuite(resolutions: [(Resolution, CGImage)], settings: Settings, sink: inout [CaseResult]) async throws {
    print("\n## Precision: 8-bit vs 16-bit float storage\n")
    printHeader()
    let cases: [(String, ImagePipeline)] = [
        ("10 per-pixel", try pipelineCases()[2].1),
        ("GaussianBlur σ=8", ImagePipeline { GaussianBlur(radius: 8) }),
        ("5-stage", try pipelineCases()[0].1),
        ("10-stage", try pipelineCases()[1].1),
    ]
    let renderer = try Renderer()
    for (res, image) in resolutions {
        let standard = makeTexture(from: image), high = makeTexture16F(from: image)
        for (name, pipeline) in cases {
            for (label, texture) in [("8-bit", standard), ("float16", high)] {
                let r = try await measureTexture(suite: "precision", name: "\(name) [texture, \(label)]", pipeline: pipeline, input: texture, resolution: res, renderer: renderer, settings: settings)
                printRow(r); sink.append(r)
            }
        }
        for (name, pipeline) in cases.filter({ $0.0 == "5-stage" }) {
            for (label, precision) in [("8-bit", Precision.standard), ("float16", .high)] {
                let r = try await measure(suite: "precision", name: "\(name) [CGImage, \(label)]", pipeline: pipeline, image: image, resolution: res, renderer: renderer, settings: settings, precision: precision)
                printRow(r); sink.append(r)
            }
        }
    }
}
