// NodeTimer.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal

/// Per-pass GPU timestamps via a counter sample buffer.
///
/// Apple GPUs sample only at encoder boundaries, so each timed pass needs its own compute
/// encoder; slot `2i` is the start and `2i + 1` the end of pass `i`. Not thread-safe: one
/// instance belongs to one render.
final class NodeTimer {
    private let buffer: any MTLCounterSampleBuffer
    let sampleCount: Int

    /// Returns `nil` when the device cannot timestamp compute encoders.
    init?(device: any MTLDevice, passes: Int) {
        guard passes > 0,
              device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else { return nil }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set
        descriptor.storageMode = .shared
        descriptor.sampleCount = passes * 2
        guard let buffer = try? device.makeCounterSampleBuffer(descriptor: descriptor) else { return nil }
        self.buffer = buffer
        self.sampleCount = passes * 2
    }

    func attach(to descriptor: MTLComputePassDescriptor, pass: Int) {
        let attachment = descriptor.sampleBufferAttachments[0]
        attachment?.sampleBuffer = buffer
        attachment?.startOfEncoderSampleIndex = pass * 2
        attachment?.endOfEncoderSampleIndex = pass * 2 + 1
    }

    /// Raw GPU ticks (`start, end` per pass), or `nil` if any sample is invalid.
    /// Only valid after the command buffer completed.
    func resolveTicks() -> [UInt64]? {
        guard let data = try? buffer.resolveCounterRange(0..<sampleCount) else { return nil }
        let ticks = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)).map(\.timestamp) }
        guard ticks.count == sampleCount, !ticks.contains(UInt64.max) else { return nil }
        return ticks
    }
}
