// ComputeDispatch.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal

extension MTLComputeCommandEncoder {
    /// Dispatches one thread per pixel of `size`, choosing a threadgroup shape from the
    /// pipeline's execution width (a full SIMD-group wide, as tall as the limit allows).
    ///
    /// Uses non-uniform threadgroups (`dispatchThreads`), so kernels need no
    /// bounds check for the dispatched grid; they still guard when reading neighbours.
    func dispatch(_ pipeline: any MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}

/// What the GPU reported about a completed command buffer.
struct GPUCompletion: Sendable {
    /// Metal's own GPU start/end timestamps for the buffer, in seconds.
    var gpuStart: Double
    var gpuEnd: Double
    /// GPU timestamp ticks per second, measured from paired CPU/GPU clock samples taken at
    /// commit and at completion. `nil` unless requested.
    var ticksPerSecond: Double?

    var duration: Double { gpuEnd - gpuStart }
}

extension MTLComputeCommandEncoder {
    /// Dispatches a tiled pass: sets threadgroup memory for the tile and uses the tile's shape.
    /// Returns `false` (having dispatched nothing) if the GPU cannot run the configuration, so the
    /// caller can report it.
    func dispatchTiled(_ pipeline: any MTLComputePipelineState, tiling: BlurTiling, width: Int, height: Int) -> Bool {
        guard let config = tiling.configuration(maxThreads: pipeline.maxTotalThreadsPerThreadgroup),
              config.memoryBytes <= pipeline.device.maxThreadgroupMemoryLength else { return false }
        setThreadgroupMemoryLength(config.memoryBytes, index: 0)
        let grid = tiling.gridSize(width: width, height: height)
        dispatchThreads(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: config.width, height: config.height, depth: 1))
        return true
    }
}

extension MTLCommandBuffer {
    /// Commits the buffer and suspends until the GPU finishes, without blocking a thread.
    ///
    /// Throws `PrismError.commandBufferFailed` if the GPU reports an error.
    /// - Parameter calibrateTicks: also measure the GPU timestamp rate (needed to convert
    ///   counter-sample ticks to seconds).
    @discardableResult
    nonisolated(nonsending) func commitAndWait(calibrateTicks: Bool = false) async throws -> GPUCompletion {
        let before = calibrateTicks ? device.sampleTimestamps() : nil
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GPUCompletion, any Error>) in
            addCompletedHandler { buffer in
                if buffer.status == .error {
                    let reason = buffer.error?.localizedDescription ?? "unknown GPU error"
                    continuation.resume(throwing: PrismError.commandBufferFailed(reason: reason))
                    return
                }
                var rate: Double?
                if let before {
                    // `sampleTimestamps` reports the CPU clock in nanoseconds.
                    let after = buffer.device.sampleTimestamps()
                    let cpuSeconds = Double(after.cpu &- before.cpu) * 1e-9
                    if cpuSeconds > 0, after.gpu > before.gpu { rate = Double(after.gpu - before.gpu) / cpuSeconds }
                }
                continuation.resume(returning: GPUCompletion(
                    gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime, ticksPerSecond: rate))
            }
            commit()
        }
    }
}
