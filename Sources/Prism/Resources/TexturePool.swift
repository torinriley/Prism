// TexturePool.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal
import os

/// A shared pool of reusable intermediate textures, keyed by size and pixel format.
///
/// **Ownership rule.** A texture is in exactly one of two places: the free list (idle,
/// no GPU work references it) or leased to a render. `release` must only be called once
/// every command buffer that used the texture has *completed*. ``Renderer`` guarantees
/// this by releasing in a `defer` that runs after `await commandBuffer.commitAndWait()`
/// has returned (or before anything was committed). Intra-render reuse never goes through
/// this pool; see ``ResourcePlan``.
///
/// All pooled textures are `rgba`-style 2D textures with `shaderRead | shaderWrite` usage
/// and CPU-visible storage (so results can be read back without a copy). Recycled textures
/// contain stale data; every kernel writes every pixel it is dispatched over.
///
/// Concurrency: one unfair lock guards the bookkeeping. Texture creation happens outside
/// the lock so a slow allocation never blocks other renders' acquire/release.
final class TexturePool: Sendable {
    struct Statistics: Sendable, Equatable {
        /// Textures created by the device.
        var allocations = 0
        /// Acquisitions satisfied from the free list.
        var reuses = 0
        /// Textures currently leased out.
        var activeTextures = 0
        /// High-water mark of `activeTextures`.
        var peakActiveTextures = 0
        /// Idle textures held for reuse.
        var pooledTextures = 0
        /// Idle textures dropped because the pool was over budget.
        var evictions = 0
        /// Device-reported size of all live pool-managed textures (leased + idle).
        var residentBytes = 0
        /// High-water mark of `residentBytes`.
        var peakResidentBytes = 0
    }

    private struct State {
        var free: [TextureDescriptor: [any MTLTexture]] = [:]
        var idleBytes = 0
        var leasedBytes = 0
        var stats = Statistics()

        mutating func noteLease(bytes: Int) {
            leasedBytes += bytes
            stats.activeTextures += 1
            stats.peakActiveTextures = max(stats.peakActiveTextures, stats.activeTextures)
            publishResidency()
        }

        mutating func publishResidency() {
            stats.residentBytes = idleBytes + leasedBytes
            stats.peakResidentBytes = max(stats.peakResidentBytes, stats.residentBytes)
        }
    }

    private let context: MetalContext
    private let budgetBytes: Int
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// - Parameter budgetBytes: Most idle (not leased) memory the pool retains. Textures
    ///   released beyond this are freed instead of pooled.
    init(context: MetalContext, budgetBytes: Int) {
        self.context = context
        self.budgetBytes = budgetBytes
    }

    func acquire(_ descriptor: TextureDescriptor) throws -> any MTLTexture {
        try acquireTracked(descriptor).texture
    }

    /// `reused` is `true` when the texture came from the free list.
    func acquireTracked(_ descriptor: TextureDescriptor) throws -> (texture: any MTLTexture, reused: Bool) {
        let recycled: (any MTLTexture)? = state.withLockUnchecked { state in
            guard let texture = state.free[descriptor]?.popLast() else { return nil }
            state.idleBytes -= texture.allocatedSize
            state.stats.reuses += 1
            state.stats.pooledTextures -= 1
            state.noteLease(bytes: texture.allocatedSize)
            return texture
        }
        if let recycled { return (recycled, true) }

        let texture = try context.makeTexture(
            width: descriptor.width, height: descriptor.height, pixelFormat: descriptor.pixelFormat)
        state.withLockUnchecked { state in
            state.stats.allocations += 1
            state.noteLease(bytes: texture.allocatedSize)
        }
        return (texture, false)
    }

    /// Leases one texture per descriptor, or none: on failure everything acquired so far is returned.
    /// `allocations` counts how many of them were newly created.
    func acquireTracked(_ descriptors: [TextureDescriptor]) throws -> (textures: [any MTLTexture], allocations: Int) {
        var leased: [any MTLTexture] = []
        var allocations = 0
        do {
            for descriptor in descriptors {
                let (texture, reused) = try acquireTracked(descriptor)
                leased.append(texture)
                if !reused { allocations += 1 }
            }
        } catch {
            release(leased)
            throw error
        }
        return (leased, allocations)
    }

    func acquire(_ descriptors: [TextureDescriptor]) throws -> [any MTLTexture] {
        try acquireTracked(descriptors).textures
    }

    /// Returns a leased texture. Precondition: no un-completed GPU work references it.
    func release(_ texture: any MTLTexture) {
        let key = TextureDescriptor(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
        let size = texture.allocatedSize
        state.withLockUnchecked { state in
            state.leasedBytes -= size
            state.stats.activeTextures -= 1
            if state.idleBytes + size <= budgetBytes {
                state.free[key, default: []].append(texture)
                state.idleBytes += size
                state.stats.pooledTextures += 1
            } else {
                state.stats.evictions += 1   // `texture` is freed when the last reference drops
            }
            state.publishResidency()
        }
    }

    func release(_ textures: [any MTLTexture]) {
        for texture in textures { release(texture) }
    }

    /// Frees every idle texture. Leased textures are unaffected.
    func purge() {
        state.withLockUnchecked { state in
            state.free.removeAll()
            state.idleBytes = 0
            state.stats.pooledTextures = 0
            state.publishResidency()
        }
    }

    var statistics: Statistics { state.withLockUnchecked { $0.stats } }
}
