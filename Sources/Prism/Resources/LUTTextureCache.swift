// LUTTextureCache.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation
import Metal
import os

/// Keeps the GPU textures of recently used 3D LUTs so they are uploaded once, not on every render.
///
/// Entries are keyed by ``LUT3D``'s identity (copies of one LUT share it), hold the immutable
/// texture a `prism_lut` pass reads, and are evicted least-recently-used once the byte budget is
/// exceeded. Evicting a texture a command buffer is still using is safe: an encoder retains every
/// resource it references until the buffer completes.
///
/// A miss builds the texture while holding the lock, so concurrent renders of the same LUT upload
/// it exactly once (an upload is ~0.4 ms, and happens once per LUT per cache lifetime).
final class LUTTextureCache: Sendable {
    struct Statistics: Sendable, Equatable {
        var uploads = 0
        var hits = 0
        var cachedLUTs = 0
        var cachedBytes = 0
    }

    private struct Entry {
        var texture: any MTLTexture
        var bytes: Int
        var lastUse: UInt64
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        var bytes = 0
        var clock: UInt64 = 0
        var uploads = 0
        var hits = 0
    }

    private let context: MetalContext
    private let budgetBytes: Int
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(context: MetalContext, budgetBytes: Int) {
        self.context = context
        self.budgetBytes = budgetBytes
    }

    func texture(for lut: LUT3D) throws -> any MTLTexture {
        try state.withLockUnchecked { state in
            state.clock += 1
            if var entry = state.entries[lut.id] {
                entry.lastUse = state.clock
                state.entries[lut.id] = entry
                state.hits += 1
                return entry.texture
            }
            let texture = try context.makeLUTTexture(lut)
            state.uploads += 1
            let bytes = texture.allocatedSize
            guard bytes <= budgetBytes else { return texture }   // too big to keep; still correct

            while state.bytes + bytes > budgetBytes, let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
                state.bytes -= oldest.value.bytes
                state.entries[oldest.key] = nil
            }
            state.entries[lut.id] = Entry(texture: texture, bytes: bytes, lastUse: state.clock)
            state.bytes += bytes
            return texture
        }
    }

    func purge() {
        state.withLockUnchecked { state in
            state.entries.removeAll()
            state.bytes = 0
        }
    }

    var statistics: Statistics {
        state.withLockUnchecked {
            Statistics(uploads: $0.uploads, hits: $0.hits, cachedLUTs: $0.entries.count, cachedBytes: $0.bytes)
        }
    }
}
