// Renderer.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import Metal
import os

/// Owns the GPU resources needed to run pipelines: device, queue, shaders, pipeline cache,
/// texture pool.
///
/// A `Renderer` is cheap to share and safe to use from many tasks concurrently. Each
/// `render` call encodes into its own command buffer; calls are not serialized by the
/// renderer (it is deliberately not an actor), so independent renders can overlap on the GPU.
public final class Renderer: Sendable {
    let context: MetalContext
    let pipelineCache: PipelineCache
    let texturePool: TexturePool
    let lutCache: LUTTextureCache
    private let signposter: OSSignposter
    /// Whether `.detailed` instrumentation may request per-pass GPU timestamps. `false` behaves exactly like a
    /// GPU that cannot provide them (tests use it to exercise that path on hardware that can).
    private let perPassTimestamps: Bool
    let optimizations: OptimizationOptions

    /// How much this renderer measures. See ``InstrumentationLevel``.
    public let instrumentation: InstrumentationLevel

    /// - Parameters:
    ///   - instrumentation: Measurement level. Default `.standard`.
    ///   - optimizations: Graph optimizations to apply. Default ``OptimizationOptions/all``.
    ///   - texturePoolBudget: Most idle texture memory, in bytes, kept for reuse between
    ///     renders. Default 512 MiB.
    /// - Throws: `PrismError.metalUnavailable` or `.shaderLibraryUnavailable`.
    public convenience init(
        instrumentation: InstrumentationLevel = .standard,
        optimizations: OptimizationOptions = .all,
        texturePoolBudget: Int = 512 * 1024 * 1024
    ) throws {
        try self.init(
            context: MetalContext(), instrumentation: instrumentation, optimizations: optimizations,
            texturePoolBudget: texturePoolBudget)
    }

    /// For tests: a renderer on a specific context (for example one that compiles shaders from source).
    init(
        context: MetalContext,
        instrumentation: InstrumentationLevel = .standard,
        optimizations: OptimizationOptions = .all,
        texturePoolBudget: Int = 512 * 1024 * 1024,
        perPassTimestamps: Bool = true
    ) {
        self.context = context
        self.perPassTimestamps = perPassTimestamps
        self.optimizations = optimizations
        self.instrumentation = instrumentation
        signposter = Signposts.signposter(for: instrumentation)
        pipelineCache = PipelineCache(context: context, instrumentation: instrumentation)
        texturePool = TexturePool(context: context, budgetBytes: texturePoolBudget)
        lutCache = LUTTextureCache(context: context, budgetBytes: 64 * 1024 * 1024)
    }

    /// Frees all idle pooled textures and cached LUT textures (for example on a memory warning).
    public func purgeTexturePool() {
        texturePool.purge()
        lutCache.purge()
    }

    /// Lifetime totals across every render on this renderer.
    public var statistics: RendererStatistics {
        let cache = pipelineCache.statistics, pool = texturePool.statistics, luts = lutCache.statistics
        return RendererStatistics(
            pipelineCacheHits: cache.hits, pipelineCacheMisses: cache.misses, cachedPipelines: cache.cachedPipelines,
            textureAllocations: pool.allocations, textureReuses: pool.reuses, activeTextures: pool.activeTextures,
            peakActiveTextures: pool.peakActiveTextures, pooledTextures: pool.pooledTextures,
            textureEvictions: pool.evictions, residentTextureBytes: pool.residentBytes,
            peakResidentTextureBytes: pool.peakResidentBytes,
            lutTextureUploads: luts.uploads, lutTextureHits: luts.hits, cachedLUTBytes: luts.cachedBytes)
    }

    /// Process-wide renderer used when `ImagePipeline.render` isn't given one.
    /// One device and queue per process is the normal Metal arrangement.
    private static let sharedState = OSAllocatedUnfairLock<Result<Renderer, PrismError>?>(initialState: nil)

    static func shared() throws -> Renderer {
        try sharedState.withLock { state in
            if let state { return try state.get() }
            let result: Result<Renderer, PrismError>
            do { result = .success(try Renderer()) }
            catch { result = .failure(error as? PrismError ?? .metalUnavailable) }
            state = result
            return try result.get()
        }
    }

    // MARK: Rendering

    func render(_ operations: [any ImageOperation], input image: CGImage, precision: Precision) async throws -> CGImage {
        try await renderWithMetrics(operations, input: image, precision: precision).image
    }

    func renderWithMetrics(_ operations: [any ImageOperation], input image: CGImage, precision: Precision) async throws -> RenderResult {
        let clock = ContinuousClock()
        let start = clock.now
        let renderID = signposter.makeSignpostID()
        let renderInterval = signposter.beginInterval("Render", id: renderID)
        defer { signposter.endInterval("Render", renderInterval) }

        let descriptor = TextureDescriptor(width: image.width, height: image.height, pixelFormat: precision.pixelFormat)
        // Validate everything before touching the GPU.
        let (graph, sourceID) = try RenderGraph.chain(operations, source: descriptor)

        let importStart = clock.now
        let (source, sourceReused) = try texturePool.acquireTracked(descriptor)
        defer { texturePool.release(source) }   // runs after `execute` has awaited GPU completion
        try CGImageInterop.upload(image, to: source)
        let importDuration = clock.now - importStart

        var exportDuration: Duration = .zero
        var outputSize = ImageSize(width: image.width, height: image.height)
        let (cgImage, trace) = try await execute(graph, sources: [sourceID: source], readsBackOnCPU: true) { output -> CGImage in
            let exportStart = clock.now
            defer { exportDuration = clock.now - exportStart }
            outputSize = ImageSize(width: output.width, height: output.height)
            return try CGImageInterop.makeCGImage(from: output)
        }

        let metrics = makeMetrics(
            inputSize: ImageSize(width: image.width, height: image.height), outputSize: outputSize,
            total: (clock.now - start).seconds, importDuration: importDuration.seconds, exportDuration: exportDuration.seconds,
            trace: trace, pooledSource: (sourceReused, source.allocatedSize))
        return RenderResult(image: cgImage, metrics: metrics)
    }

    // MARK: Texture in, texture out

    nonisolated(nonsending) func renderTexture(
        _ operations: [any ImageOperation], input: any MTLTexture, destination: (any MTLTexture)?
    ) async throws -> (texture: any MTLTexture, metrics: RenderMetrics) {
        let clock = ContinuousClock()
        let start = clock.now
        let renderID = signposter.makeSignpostID()
        let renderInterval = signposter.beginInterval("Render", id: renderID)
        defer { signposter.endInterval("Render", renderInterval) }

        try validateInput(input)
        let descriptor = TextureDescriptor(width: input.width, height: input.height, pixelFormat: input.pixelFormat)
        let (graph, sourceID) = try RenderGraph.chain(operations, source: descriptor)

        let (texture, trace) = try await execute(
            graph, sources: [sourceID: input], output: destination.map { .caller($0) } ?? .allocate
        ) { $0 }
        let metrics = makeMetrics(
            inputSize: ImageSize(width: input.width, height: input.height),
            outputSize: ImageSize(width: texture.width, height: texture.height),
            total: (clock.now - start).seconds, importDuration: nil, exportDuration: nil,
            trace: trace, pooledSource: nil)
        return (texture, metrics)
    }

    private static let supportedTextureFormats: Set<MTLPixelFormat> = [.rgba8Unorm, .bgra8Unorm, .rgba16Float]

    private func validateInput(_ texture: any MTLTexture) throws {
        guard texture.device.registryID == context.device.registryID else {
            throw PrismError.incompatibleResources(reason: "the input texture belongs to a different GPU")
        }
        guard texture.textureType == .type2D, texture.sampleCount == 1 else {
            throw PrismError.unsupportedImage(reason: "the input must be a single-sample 2D texture")
        }
        guard Self.supportedTextureFormats.contains(texture.pixelFormat) else {
            throw PrismError.unsupportedImage(
                reason: "pixel format \(texture.pixelFormat) is not supported; use rgba8Unorm, bgra8Unorm or rgba16Float")
        }
        guard texture.usage.contains(.shaderRead), texture.storageMode != .memoryless else {
            throw PrismError.unsupportedImage(reason: "the input texture must allow shader reads (usage .shaderRead)")
        }
    }

    private func validateDestination(
        _ texture: any MTLTexture, expecting descriptor: TextureDescriptor, inputs: [any MTLTexture]
    ) throws {
        guard texture.device.registryID == context.device.registryID else {
            throw PrismError.incompatibleResources(reason: "the destination texture belongs to a different GPU")
        }
        guard texture.textureType == .type2D, texture.sampleCount == 1, texture.storageMode != .memoryless else {
            throw PrismError.incompatibleResources(reason: "the destination must be a single-sample 2D texture")
        }
        guard texture.width == descriptor.width, texture.height == descriptor.height,
              texture.pixelFormat == descriptor.pixelFormat else {
            throw PrismError.incompatibleResources(
                reason: "the pipeline produces \(descriptor.width)×\(descriptor.height) \(descriptor.pixelFormat), but the destination is \(texture.width)×\(texture.height) \(texture.pixelFormat)")
        }
        guard texture.usage.contains(.shaderRead), texture.usage.contains(.shaderWrite) else {
            throw PrismError.incompatibleResources(reason: "the destination texture needs usage .shaderRead and .shaderWrite")
        }
        guard !inputs.contains(where: { $0 === texture }) else {
            throw PrismError.incompatibleResources(reason: "the destination must not be the input texture")
        }
    }

    // MARK: Metrics

    private func makeMetrics(
        inputSize: ImageSize, outputSize: ImageSize, total: TimeInterval,
        importDuration: TimeInterval?, exportDuration: TimeInterval?,
        trace: ExecutionTrace, pooledSource: (reused: Bool, bytes: Int)?
    ) -> RenderMetrics {
        let measured = instrumentation >= .standard
        return RenderMetrics(
            level: instrumentation,
            inputSize: inputSize,
            outputSize: outputSize,
            totalDuration: total,
            importDuration: measured ? importDuration : nil,
            cpuEncodeDuration: measured ? trace.encodeDuration : nil,
            gpuDuration: measured ? trace.gpuDuration : nil,
            exportDuration: measured ? exportDuration : nil,
            nodes: trace.nodes,
            textureAllocations: trace.allocations + (pooledSource.map { $0.reused ? 0 : 1 } ?? 0),
            textureReuses: trace.leasedSlots - trace.allocations + (pooledSource.map { $0.reused ? 1 : 0 } ?? 0),
            peakActiveTextures: trace.slots + (pooledSource == nil ? 0 : 1),
            logicalTextures: trace.logicalTextures + (pooledSource == nil ? 0 : 1),
            peakTextureBytes: trace.slotBytes + (pooledSource?.bytes ?? 0),
            pipelineCacheHits: trace.cacheHits,
            pipelineCacheMisses: trace.cacheMisses,
            eliminatedPasses: trace.eliminatedPasses)
    }

    /// Where a render's final texture comes from.
    enum OutputTarget {
        /// A slot leased from the pool, valid only inside the `consume` closure.
        case pooled
        /// A new texture the caller owns.
        case allocate
        /// A texture the caller supplied.
        case caller(any MTLTexture)
    }

    /// Everything `execute` measured about one graph execution.
    struct ExecutionTrace {
        var encodeDuration: TimeInterval = 0
        var gpuDuration: TimeInterval = 0
        var nodes: [NodeMetrics] = []
        var allocations = 0
        var slots = 0
        /// Slots taken from the pool (all of them, unless the caller supplied the output texture).
        var leasedSlots = 0
        var logicalTextures = 0
        var slotBytes = 0
        var cacheHits = 0
        var cacheMisses = 0
        var eliminatedPasses = 0
    }

    /// Validates, plans and executes a graph, then hands the output texture to `consume`.
    ///
    /// The output texture is only valid inside `consume`: afterwards its memory returns to
    /// the pool. `consume` runs after the GPU has finished.
    nonisolated(nonsending) func execute<T>(
        _ original: RenderGraph, sources originalSources: [NodeID: any MTLTexture],
        output target: OutputTarget = .pooled,
        readsBackOnCPU: Bool = false,
        consuming consume: (any MTLTexture) throws -> T
    ) async throws -> (value: T, trace: ExecutionTrace) {
        let clock = ContinuousClock()
        let encodeStart = clock.now
        var trace = ExecutionTrace()

        try original.validate()
        let optimized = GraphOptimizer(options: optimizations).optimize(original)
        let graph = optimized.graph
        // Source textures are keyed by the caller's node ids; re-key them for the rewritten graph.
        let sources = Dictionary(uniqueKeysWithValues: originalSources.compactMap { key, texture in
            optimized.map[key].map { ($0, texture) }
        })
        trace.eliminatedPasses = optimized.removedPasses
        let plan = try ExecutionPlan(graph: graph)
        let resources = ResourcePlan(graph: graph, plan: plan)

        // Where the final result goes. A caller-supplied or freshly allocated texture takes the
        // place of the output node's pooled slot, so the last pass writes straight into it.
        let outputDescriptor = graph.node(graph.output!).output
        let override: (any MTLTexture)?
        switch target {
        case .pooled:
            override = nil
        case .allocate:
            override = try context.makeTexture(
                width: outputDescriptor.width, height: outputDescriptor.height, pixelFormat: outputDescriptor.pixelFormat)
        case .caller(let texture):
            try validateDestination(texture, expecting: outputDescriptor, inputs: Array(originalSources.values))
            override = texture
        }
        let overriddenSlot = override.flatMap { _ in resources.slot[graph.output!] }

        // LIFETIME INVARIANT: these textures go back to the pool only when this function
        // exits, and every exit path is either before `commit()` (nothing references them)
        // or after `commitAndWait()` returned/threw (the GPU has finished with the buffer).
        // The awaiting task is never abandoned mid-flight, so there is no path that
        // releases a texture while the GPU still uses it.
        let leaseDescriptors = resources.slots.enumerated().filter { $0.offset != overriddenSlot }.map(\.element)
        let (leased, allocations) = try texturePool.acquireTracked(leaseDescriptors)
        defer { texturePool.release(leased) }
        var slots: [any MTLTexture] = []
        var leasedIterator = leased.makeIterator()
        for index in resources.slots.indices {
            slots.append(index == overriddenSlot ? override! : leasedIterator.next()!)
        }
        trace.allocations = allocations
        trace.slots = slots.count
        trace.leasedSlots = leased.count
        trace.logicalTextures = resources.logicalTextures
        trace.slotBytes = slots.reduce(0) { $0 + $1.allocatedSize }

        let id = signposter.makeSignpostID()
        let encodeInterval = signposter.beginInterval("Encode", id: id)
        let encoded: Encoded
        do { encoded = try encode(graph, plan, resources, slots: slots, sources: sources, copyOutputTo: overriddenSlot == nil ? override : nil, readsBackOnCPU: readsBackOnCPU) }
        catch { signposter.endInterval("Encode", encodeInterval); throw error }
        signposter.endInterval("Encode", encodeInterval)
        trace.encodeDuration = (clock.now - encodeStart).seconds
        trace.cacheHits = encoded.cacheHits
        trace.cacheMisses = encoded.cacheMisses

        // Cancellation boundary: past this point the work is on the GPU and cannot be
        // recalled, so we deliberately do not race the await against cancellation.
        try Task.checkCancellation()
        let gpuInterval = signposter.beginInterval("GPU", id: id)
        let gpu = try await encoded.commandBuffer.commitAndWait(calibrateTicks: encoded.timer != nil)
        signposter.endInterval("GPU", gpuInterval)
        trace.gpuDuration = gpu.duration

        let timings = encoded.timer.flatMap { Self.durations(from: $0, gpu: gpu) }
        trace.nodes = encoded.computeNodes.enumerated().map { index, node in
            NodeMetrics(
                name: node.name,
                outputSize: ImageSize(width: node.output.width, height: node.output.height),
                gpuDuration: timings?[index])
        }
        return (try consume(encoded.output), trace)
    }

    /// Convenience for callers that only need the output.
    nonisolated(nonsending) func run<T>(
        _ graph: RenderGraph, sources: [NodeID: any MTLTexture],
        consuming consume: (any MTLTexture) throws -> T
    ) async throws -> T {
        try await execute(graph, sources: sources, consuming: consume).value
    }

    /// Converts per-pass GPU ticks to seconds using the measured timestamp rate.
    private static func durations(from timer: NodeTimer, gpu: GPUCompletion) -> [TimeInterval]? {
        guard let rate = gpu.ticksPerSecond, let ticks = timer.resolveTicks() else { return nil }
        return stride(from: 0, to: ticks.count, by: 2).map { Double(ticks[$0 + 1] &- ticks[$0]) / rate }
    }

    private struct Encoded {
        var commandBuffer: any MTLCommandBuffer
        var output: any MTLTexture
        var cacheHits: Int
        var cacheMisses: Int
        var computeNodes: [RenderGraph.Node]
        var timer: NodeTimer?
    }

    /// Encodes the plan into one command buffer. At `.standard` and below all passes share one
    /// serial compute encoder, which finishes each dispatch before starting the next, so every
    /// dispatch observes the writes of the ones before it. At `.detailed` each pass gets its own
    /// encoder (in order) so it can be timestamped.
    private func encode(
        _ graph: RenderGraph, _ plan: ExecutionPlan, _ resources: ResourcePlan,
        slots: [any MTLTexture], sources: [NodeID: any MTLTexture],
        copyOutputTo copyDestination: (any MTLTexture)?, readsBackOnCPU: Bool
    ) throws -> Encoded {
        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            throw PrismError.commandBufferFailed(reason: "could not create command buffer")
        }
        let computeNodes = plan.order.map { graph.node($0) }.filter { if case .compute = $0.work { true } else { false } }
        let timer = instrumentation == .detailed && perPassTimestamps ? NodeTimer(device: context.device, passes: computeNodes.count) : nil

        var openEncoder: (any MTLComputeCommandEncoder)?
        func encoder(forPass pass: Int) throws -> any MTLComputeCommandEncoder {
            if let openEncoder { return openEncoder }
            let made: (any MTLComputeCommandEncoder)?
            if let timer {
                let descriptor = MTLComputePassDescriptor()
                timer.attach(to: descriptor, pass: pass)
                made = commandBuffer.makeComputeCommandEncoder(descriptor: descriptor)
            } else {
                made = commandBuffer.makeComputeCommandEncoder()
            }
            guard let made else { throw PrismError.commandBufferFailed(reason: "could not create compute encoder") }
            openEncoder = made
            return made
        }

        var cacheHits = 0, cacheMisses = 0
        var textures: [NodeID: any MTLTexture] = [:]
        var passIndex = 0
        do {
            for id in plan.order {
                try Task.checkCancellation()
                let node = graph.node(id)
                switch node.work {
                case .source:
                    guard let texture = sources[id] else {
                        throw PrismError.invalidGraph(reason: "no texture supplied for source '\(node.name)'")
                    }
                    guard texture.width == node.output.width, texture.height == node.output.height,
                          texture.pixelFormat == node.output.pixelFormat else {
                        throw PrismError.incompatibleResources(
                            reason: "texture for '\(node.name)' does not match its descriptor")
                    }
                    textures[id] = texture
                case .compute(let pass):
                    let (pipeline, hit) = try pipelineCache.lookup(kernel: pass.kernel)
                    if hit { cacheHits += 1 } else { cacheMisses += 1 }
                    let destination = slots[resources.slot[id]!]
                    let encoder = try encoder(forPass: passIndex)
                    encoder.setComputePipelineState(pipeline)
                    for (slot, input) in node.inputs.enumerated() {
                        encoder.setTexture(textures[input], index: slot)
                    }
                    encoder.setTexture(destination, index: node.inputs.count)
                    if let lut = pass.lut {
                        encoder.setTexture(try lutCache.texture(for: lut), index: node.inputs.count + 1)
                    }
                    if !pass.uniforms.isEmpty {
                        pass.uniforms.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
                    }
                    if !pass.constants.isEmpty {
                        pass.constants.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                    }
                    if let tiling = pass.tiling {
                        guard encoder.dispatchTiled(pipeline, tiling: tiling, width: node.output.width, height: node.output.height) else {
                            throw PrismError.pipelineCreationFailed(
                                kernel: pass.kernel, reason: "this GPU cannot provide the threadgroup memory a \(tiling) tile needs")
                        }
                    } else {
                        encoder.dispatch(pipeline, width: node.output.width, height: node.output.height)
                    }
                    textures[id] = destination
                    passIndex += 1
                    if timer != nil { encoder.endEncoding(); openEncoder = nil }
                }
            }
        } catch {
            openEncoder?.endEncoding()   // an encoder must be ended before it is released
            throw error
        }
        openEncoder?.endEncoding()

        var output = textures[graph.output!]!
        // The pipeline did no GPU work (every pass was eliminated), so the result *is* the input;
        // the caller asked for it in a texture of their own, so copy it there.
        if let copyDestination, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: output, to: copyDestination)
            blit.endEncoding()
            output = copyDestination
        }
        // A texture the GPU has written is stored in a GPU-optimized layout that is several times
        // slower for the CPU to read (measured: 12 ms vs 1.5 ms for 4K RGBA8). When the CPU is going
        // to read the result, have the GPU convert it first. Skipped for source textures (the CPU
        // wrote those) and for GPU-only consumers, which want the optimized layout.
        if readsBackOnCPU, output.storageMode != .private, slots.contains(where: { $0 === output }),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.optimizeContentsForCPUAccess(texture: output)
            blit.endEncoding()
        }
        #if os(macOS)
        if output.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)   // make GPU writes visible to the CPU (discrete GPUs)
            blit.endEncoding()
        }
        #endif
        return Encoded(
            commandBuffer: commandBuffer, output: output, cacheHits: cacheHits, cacheMisses: cacheMisses,
            computeNodes: computeNodes, timer: timer)
    }
}

extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) * 1e-18 }
}
