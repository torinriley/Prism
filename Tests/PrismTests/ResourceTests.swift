// ResourceTests.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal
import Testing
@testable import Prism

private let pass = ComputePass(kernel: "prism_invert")

private func chain(_ count: Int, size: TextureDescriptor = .init(width: 8, height: 8)) -> RenderGraph {
    var g = RenderGraph()
    var current = g.addSource("Input", descriptor: size)
    for i in 0..<count { current = g.addPass("N\(i)", pass, inputs: [current], output: size) }
    g.setOutput(current)
    return g
}

@Suite("ResourcePlan")
struct ResourcePlanTests {
    @Test("A chain needs only two physical textures, however long")
    func chainUsesTwoSlots() throws {
        for count in [1, 2, 3, 10, 100] {
            let g = chain(count)
            let r = ResourcePlan(graph: g, plan: try ExecutionPlan(graph: g))
            #expect(r.logicalTextures == count)
            #expect(r.slots.count == min(count, 2), "chain of \(count)")
        }
    }

    @Test("Diamond: four logical textures in three slots")
    func diamond() throws {
        let d = TextureDescriptor(width: 8, height: 8)
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", pass, inputs: [input], output: d)
        let b = g.addPass("B", pass, inputs: [a], output: d)
        let c = g.addPass("C", pass, inputs: [a], output: d)
        g.setOutput(g.addPass("D", pass, inputs: [b, c], output: d))
        let r = ResourcePlan(graph: g, plan: try ExecutionPlan(graph: g))
        #expect(r.logicalTextures == 4 && r.slots.count == 3)
        #expect(r.slot[NodeID(rawValue: 4)] == r.slot[a], "D reuses A's slot: A died when C read it")
    }

    @Test("Textures of different sizes never share a slot")
    func differentSizes() throws {
        var g = RenderGraph()
        let small = TextureDescriptor(width: 4, height: 4), big = TextureDescriptor(width: 8, height: 8)
        var resize = pass; resize.inputsMatchOutputSize = false
        let input = g.addSource("Input", descriptor: big)
        let a = g.addPass("Down", resize, inputs: [input], output: small)
        let b = g.addPass("Up", resize, inputs: [a], output: big)
        let c = g.addPass("Down2", resize, inputs: [b], output: small)
        g.setOutput(c)
        let r = ResourcePlan(graph: g, plan: try ExecutionPlan(graph: g))
        for (id, slot) in r.slot { #expect(r.slots[slot] == g.node(id).output) }
        // Down (small) is dead after Up reads it, so Down2 (small) may reuse its slot.
        #expect(r.slot[a] == r.slot[c])
        #expect(r.slots.count == 2)
    }

    @Test("The output is never recycled, and the source owns no slot")
    func outputPinned() throws {
        let g = chain(3)
        let r = ResourcePlan(graph: g, plan: try ExecutionPlan(graph: g))
        #expect(r.slot[NodeID(rawValue: 0)] == nil)
        #expect(r.slot[g.output!] != nil)
    }

    @Test("An input listed twice is released once")
    func duplicateInput() throws {
        let d = TextureDescriptor(width: 8, height: 8)
        var g = RenderGraph()
        let input = g.addSource("Input", descriptor: d)
        let a = g.addPass("A", pass, inputs: [input], output: d)
        g.setOutput(g.addPass("Mix", pass, inputs: [a, a], output: d))
        let r = ResourcePlan(graph: g, plan: try ExecutionPlan(graph: g))
        #expect(r.slots.count == 2)
        #expect(r.slot[a] != r.slot[g.output!])
    }

    @Test("Random DAGs: nodes with overlapping live ranges never share a slot")
    func randomGraphsNeverAlias() throws {
        var rng = SplitMix64(seed: 0xC0FFEE)
        let sizes = [TextureDescriptor(width: 8, height: 8), TextureDescriptor(width: 4, height: 8)]
        for trial in 0..<300 {
            var g = RenderGraph()
            var ids = [g.addSource("Input", descriptor: sizes[0])]
            for n in 0..<Int.random(in: 2...25, using: &rng) {
                let fan = Int.random(in: 1...3, using: &rng)
                let inputs = (0..<fan).map { _ in ids[Int.random(in: 0..<ids.count, using: &rng)] }
                var p = pass; p.inputsMatchOutputSize = false
                ids.append(g.addPass("N\(n)", p, inputs: inputs, output: sizes[Int.random(in: 0..<2, using: &rng)]))
            }
            g.setOutput(ids.last!)
            let plan = try ExecutionPlan(graph: g)
            let r = ResourcePlan(graph: g, plan: plan)

            let position = Dictionary(uniqueKeysWithValues: plan.order.enumerated().map { ($1, $0) })
            let live = { (id: NodeID) in position[id]!...plan.lastUse[id.rawValue] }
            let compute = g.nodes.filter { r.slot[$0.id] != nil }
            for (i, x) in compute.enumerated() {
                #expect(r.slots[r.slot[x.id]!] == x.output, "trial \(trial)")
                for y in compute[(i + 1)...] where r.slot[x.id] == r.slot[y.id] {
                    #expect(!live(x.id).overlaps(live(y.id)), "trial \(trial): \(x.name) and \(y.name) alias while both live")
                }
            }
            #expect(r.slots.count <= r.logicalTextures)
        }
    }
}

/// Deterministic RNG so failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("TexturePool", .enabled(if: hasMetal))
struct TexturePoolTests {
    func makePool(budget: Int = 1 << 30) throws -> TexturePool {
        TexturePool(context: try MetalContext(), budgetBytes: budget)
    }
    let d = TextureDescriptor(width: 64, height: 32)

    @Test("Acquire allocates, release pools, the next acquire reuses the same texture")
    func reuse() throws {
        let pool = try makePool()
        let t = try pool.acquire(d)
        #expect(pool.statistics.allocations == 1 && pool.statistics.activeTextures == 1)
        pool.release(t)
        #expect(pool.statistics.pooledTextures == 1 && pool.statistics.activeTextures == 0)
        let again = try pool.acquire(d)
        #expect(ObjectIdentifier(again as AnyObject) == ObjectIdentifier(t as AnyObject))
        let s = pool.statistics
        #expect(s.allocations == 1 && s.reuses == 1 && s.peakActiveTextures == 1 && s.pooledTextures == 0)
    }

    @Test("Different descriptors don't match")
    func keyed() throws {
        let pool = try makePool()
        pool.release(try pool.acquire(d))
        _ = try pool.acquire(.init(width: 64, height: 33))
        _ = try pool.acquire(.init(width: 64, height: 32, pixelFormat: .rgba16Float))
        #expect(pool.statistics.allocations == 3 && pool.statistics.reuses == 0)
    }

    @Test("Peak active tracks simultaneous leases")
    func peak() throws {
        let pool = try makePool()
        let held = try (0..<5).map { _ in try pool.acquire(d) }
        pool.release(held)
        _ = try pool.acquire(d)
        #expect(pool.statistics.peakActiveTextures == 5)
        #expect(pool.statistics.allocations == 5 && pool.statistics.reuses == 1)
    }

    @Test("Resident bytes track allocatedSize; the budget evicts instead of retaining")
    func memoryAndBudget() throws {
        let pool = try makePool(budget: 0)
        let t = try pool.acquire(d)
        let size = t.allocatedSize
        #expect(size >= 64 * 32 * 4)
        #expect(pool.statistics.residentBytes == size)
        pool.release(t)
        let s = pool.statistics
        #expect(s.evictions == 1 && s.pooledTextures == 0 && s.residentBytes == 0 && s.peakResidentBytes == size)

        let roomy = try makePool()
        roomy.release(try roomy.acquire(d))
        #expect(roomy.statistics.residentBytes == size)
        roomy.purge()
        #expect(roomy.statistics.residentBytes == 0 && roomy.statistics.pooledTextures == 0)
    }

    @Test("Invalid sizes fail without leaking a lease")
    func failedAcquire() throws {
        let pool = try makePool()
        #expect(throws: PrismError.self) { _ = try pool.acquire([d, .init(width: 0, height: 4)]) }
        #expect(pool.statistics.activeTextures == 0 && pool.statistics.pooledTextures == 1)
    }

    @Test("Heavy contention keeps the books exact and never double-leases a texture")
    func contention() async throws {
        let pool = try makePool()
        let rounds = 200, workers = 32
        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                group.addTask {
                    for r in 0..<rounds {
                        let a = try pool.acquire(d), b = try pool.acquire(d)
                        // Exclusive ownership: stamp both with our id, yield, verify no one else wrote them.
                        let stamp = UInt8((w * 7 + r) % 251)
                        var bytes = [UInt8](repeating: stamp, count: 64 * 32 * 4)
                        for t in [a, b] { t.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 256) }
                        await Task.yield()
                        for t in [a, b] {
                            #expect(CGImageInterop.readPixels(from: t).allSatisfy { $0 == stamp })
                        }
                        pool.release(a); pool.release(b)
                    }
                }
            }
            try await group.waitForAll()
        }
        let s = pool.statistics
        #expect(s.activeTextures == 0)
        #expect(s.allocations + s.reuses == workers * rounds * 2)
        #expect(s.allocations == s.pooledTextures + s.evictions, "every allocated texture ends up idle")
        #expect(s.allocations <= workers * 2 && s.peakActiveTextures <= workers * 2)
    }
}

@Suite("Renderer resource behavior", .enabled(if: hasMetal))
struct RendererResourceTests {
    private func run(_ renderer: Renderer, _ ops: [any ImageOperation], width: Int = 64, height: Int = 48,
                     bytes: [UInt8]? = nil) async throws -> [UInt8] {
        let src = bytes ?? testPixels(width: width, height: height)
        let out = try await ImagePipeline(operations: ops).render(makeImage(width: width, height: height, bytes: src), using: renderer)
        return try pixels(of: out)
    }

    @Test("10 stages use 3 textures (source + 2 slots); a second render allocates nothing")
    func tenStagePool() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        let ops: [any ImageOperation] = (0..<10).map { i -> any ImageOperation in i.isMultiple(of: 2) ? Exposure(0.05) : Contrast(1.02) }
        _ = try await run(renderer, ops)
        let first = renderer.texturePool.statistics
        #expect(first.allocations == 3 && first.reuses == 0 && first.peakActiveTextures == 3)
        #expect(first.activeTextures == 0 && first.pooledTextures == 3)

        _ = try await run(renderer, ops)
        let second = renderer.texturePool.statistics
        #expect(second.allocations == 3, "no new allocations on a warm renderer")
        #expect(second.reuses == 3)
        #expect(second.residentBytes == first.residentBytes)
    }

    @Test("Slot reuse inside one command buffer is bit-identical to running stage by stage")
    func reuseIsCorrect() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        var ops: [any ImageOperation] = []
        for i in 0..<10 { ops.append(Exposure(Float(i % 3) * 0.15 - 0.1)); ops.append(Contrast(1.05)) }

        // One render: 20 stages, 2 recycled slots, one command buffer.
        let chained = try await run(renderer, ops)
        #expect(renderer.texturePool.statistics.allocations == 3)

        // Same stages, one render each: every stage gets distinct textures and a fresh command
        // buffer. Both paths round to 8 bits after every stage, so the results must be identical.
        var bytes = testPixels(width: 64, height: 48)
        for op in ops { bytes = try await run(try Renderer(optimizations: noFusion), [op], bytes: bytes) }
        #expect(chained == bytes)
    }

    @Test("Long-chain drift versus the Double reference is rounding, and stays bounded")
    func chainDrift() async throws {
        // Each stage rounds to 8 bits, and Contrast(1.05) amplifies earlier rounding differences,
        // so GPU-vs-Double disagreement grows with depth. This documents the size of that effect.
        let renderer = try Renderer()
        var ops: [any ImageOperation] = []
        var reference = testPixels(width: 64, height: 48)
        for i in 0..<10 {
            let stops = Float(i % 3) * 0.15 - 0.1
            ops.append(Exposure(stops)); reference = referenceExposure(reference, stops: Double(stops))
            ops.append(Contrast(1.05)); reference = referenceContrast(reference, factor: 1.05)
        }
        let out = try await run(renderer, ops)
        #expect(maxError(out, reference) <= 16, "drift \(maxError(out, reference))")
    }

    @Test("Recycled textures holding stale data don't leak into results")
    func poisonedPool() async throws {
        let renderer = try Renderer()
        let d = TextureDescriptor(width: 64, height: 48)
        let junk = try (0..<4).map { _ in try renderer.texturePool.acquire(d) }
        var garbage = [UInt8](repeating: 0xAB, count: 64 * 48 * 4)
        for t in junk { t.replace(region: MTLRegionMake2D(0, 0, 64, 48), mipmapLevel: 0, withBytes: &garbage, bytesPerRow: 256) }
        renderer.texturePool.release(junk)

        let src = testPixels(width: 64, height: 48)
        let out = try await run(renderer, [GaussianBlur(radius: 3), Sharpen(amount: 1), Vignette(amount: 0.5)], bytes: src)
        #expect(renderer.texturePool.statistics.reuses > 0, "the poisoned textures were actually reused")
        let fresh = try await run(try Renderer(), [GaussianBlur(radius: 3), Sharpen(amount: 1), Vignette(amount: 0.5)], bytes: src)
        #expect(out == fresh)
    }

    @Test("Different image sizes keep separate pooled textures and stay correct")
    func mixedSizes() async throws {
        let renderer = try Renderer(optimizations: noFusion)
        for (w, h) in [(10, 10), (33, 7), (10, 10), (33, 7)] {
            let src = testPixels(width: w, height: h)
            let out = try await run(renderer, [Exposure(0.5), Contrast(1.2)], width: w, height: h, bytes: src)
            #expect(maxError(out, referenceContrast(referenceExposure(src, stops: 0.5), factor: 1.2)) <= 2)
        }
        let s = renderer.texturePool.statistics
        #expect(s.allocations == 6 && s.reuses == 6, "3 textures per size, reused on the second visit")
        #expect(s.activeTextures == 0)
    }

    @Test("Sharpen's branch keeps the original alive without extra copies")
    func sharpenSlots() async throws {
        let renderer = try Renderer()
        _ = try await run(renderer, [Sharpen(amount: 1)])
        // source + (blurH, blurV, combine): blurH dies when blurV reads it, so combine reuses its slot.
        #expect(renderer.texturePool.statistics.allocations == 3)
    }

    @Test("Failed and cancelled renders return every lease")
    func leasesReturnedOnFailure() async throws {
        let renderer = try Renderer()
        await #expect(throws: PrismError.self) { _ = try await run(renderer, [Exposure(.nan)]) }
        let img = makeImage(width: 32, height: 32, bytes: testPixels(width: 32, height: 32))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await ImagePipeline { Exposure(1); Contrast(1.2) }.render(img, using: renderer)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(renderer.texturePool.statistics.activeTextures == 0)
        _ = try await run(renderer, [Exposure(0.2)])   // the renderer is still healthy
        #expect(renderer.texturePool.statistics.activeTextures == 0)
    }

    @Test("Concurrent renders sharing one pool are all correct and leave nothing leased")
    func concurrentRendersSharePool() async throws {
        let renderer = try Renderer()
        let sizes = [(16, 16), (40, 24), (16, 16), (128, 64)]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<48 {
                group.addTask {
                    let (w, h) = sizes[i % sizes.count]
                    let stops = Float(i % 5) * 0.2
                    let src = testPixels(width: w, height: h)
                    let out = try await ImagePipeline { Exposure(stops); Saturation(0.8); GaussianBlur(radius: 2); Exposure(-stops) }
                        .render(makeImage(width: w, height: h, bytes: src), using: renderer)
                    var ref = referenceExposure(src, stops: Double(stops))
                    ref = referenceSaturation(ref, width: w, factor: 0.8)
                    ref = referenceBlur(ref, width: w, height: h, sigma: 2)
                    ref = referenceExposure(ref, stops: -Double(stops))
                    let err = maxError(try pixels(of: out), ref)
                    #expect(err <= 3, "render \(i) (\(w)×\(h)): \(err) LSB")
                }
            }
            try await group.waitForAll()
        }
        // All 48 renders can be in flight at once (each suspends while the GPU works), so the
        // first wave may allocate everything. What must hold: nothing leaked, books balance.
        let first = renderer.texturePool.statistics
        #expect(first.activeTextures == 0 && first.peakActiveTextures >= 3)
        #expect(first.allocations == first.pooledTextures + first.evictions)

        _ = try await run(renderer, [Exposure(0.1)], width: 16, height: 16)
        #expect(renderer.texturePool.statistics.reuses > 0, "a later render reuses what the first wave released")
    }

    @Test("purgeTexturePool frees idle memory")
    func purge() async throws {
        let renderer = try Renderer()
        _ = try await run(renderer, [Exposure(0.1)])
        #expect(renderer.texturePool.statistics.residentBytes > 0)
        renderer.purgeTexturePool()
        #expect(renderer.texturePool.statistics.residentBytes == 0)
        _ = try await run(renderer, [Exposure(0.1)])   // still works after a purge
    }
}
