// PipelineCache.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal
import os

/// Caches compute pipeline states by kernel name.
///
/// Concurrency: a single unfair lock guards the dictionary. A miss compiles *while
/// holding the lock*, so N concurrent requests for one kernel compile exactly once and
/// the miss/hit counters are exact. The cost is that a cold compile of kernel A briefly
/// delays lookups of kernel B; compiles are ~ms and happen once per kernel per process.
final class PipelineCache: Sendable {
    struct Statistics: Sendable, Equatable {
        var hits = 0
        var misses = 0
        var cachedPipelines = 0
    }

    private struct State {
        var pipelines: [String: any MTLComputePipelineState] = [:]
        var hits = 0
        var misses = 0
    }

    private let context: MetalContext
    private let signposter: OSSignposter
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(context: MetalContext, instrumentation: InstrumentationLevel = .standard) {
        self.context = context
        self.signposter = Signposts.signposter(for: instrumentation)
    }

    func pipeline(kernel name: String) throws -> any MTLComputePipelineState {
        try lookup(kernel: name).pipeline
    }

    /// `hit` is `false` when this call compiled the pipeline.
    func lookup(kernel name: String) throws -> (pipeline: any MTLComputePipelineState, hit: Bool) {
        try state.withLockUnchecked { state in
            if let cached = state.pipelines[name] {
                state.hits += 1
                return (cached, true)
            }
            let interval = signposter.beginInterval("Compile pipeline", "\(name)")
            defer { signposter.endInterval("Compile pipeline", interval) }
            let pipeline = try context.makePipeline(kernel: name)
            state.pipelines[name] = pipeline
            state.misses += 1
            return (pipeline, false)
        }
    }

    var statistics: Statistics {
        state.withLockUnchecked {
            Statistics(hits: $0.hits, misses: $0.misses, cachedPipelines: $0.pipelines.count)
        }
    }
}
