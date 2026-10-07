# Prism architecture

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Prism keeps its public API deliberately smaller than its implementation. A pipeline is a value
containing operations; a renderer owns the reusable GPU infrastructure. Everything between those
two concepts is internal.

```text
ImagePipeline + CGImage/MTLTexture
              │
              ▼
        operation lowering
              │
              ▼
         RenderGraph (DAG)
              │
      identity elimination
      dead-node elimination
      pointwise fusion
              │
              ▼
         ExecutionPlan ─── deterministic topological order + lifetimes
              │
              ▼
          ResourcePlan ─── logical resources → physical texture slots
              │
              ▼
            Renderer ───── pipeline cache, texture pool, LUT cache, metrics
              │
              ▼
     Metal command buffer ─ custom compute kernels
```

## Public boundary

`ImagePipeline` and the operation structs are values and `Sendable`. `Renderer` is a shareable
reference type that owns a device, command queue and synchronized caches. It is deliberately not an
actor: independent calls encode independent command buffers and may overlap on the GPU. No backend
object enters the normal `CGImage` API. `MTLTexture` appears only in the explicit zero-round-trip
texture API.

`ImageOperation` is public for a native Swift surface, but its `OperationPlan` cannot be constructed
outside the module. This keeps Metal kernel names, bindings and resource rules out of client code.

## Ownership and concurrency

The graph and both plans are immutable values after construction. Mutable shared state is narrowly
scoped:

- `PipelineCache` serializes pipeline lookup and cold compilation under an unfair lock.
- `TexturePool` locks free-list bookkeeping but creates textures outside the lock.
- `LUTTextureCache` is an LRU cache with one upload per LUT under contention.
- Each render owns its command buffer, encoders, slot lease and instrumentation trace.

A pooled texture is either idle or leased to exactly one render. Physical slots may be reused by
multiple graph nodes only when static lifetime analysis proves their live ranges do not overlap.
Leases return to the shared pool only before submission or after command-buffer completion. That is
the central GPU-lifetime invariant.

Cancellation is effective until submission. Metal does not provide command-buffer cancellation, so
after submission Prism awaits completion and keeps resources alive.

## Pixel storage

The logical graph carries a pixel format in every resource descriptor. `Precision.standard` uses
`rgba8Unorm`; `.high` uses `rgba16Float`. Kernels perform arithmetic in 32-bit float in either case.
The texture pool keys on dimensions, format and usage, so precision modes never share incompatible
allocations. See [COLOR.md](COLOR.md) for the color contract.

## Why these boundaries

- A DAG, rather than a filter loop, is required for branches such as unsharp masking and for future
  composites.
- Optimization runs before planning, so an optimized graph gets fresh dependency and lifetime
  analysis instead of trying to patch an existing schedule.
- Resource planning is pure and testable without Metal. Allocation is a backend concern.
- Instrumentation consumes the same graph names and resource plans used for execution, preventing a
  separate inspector model from drifting from reality.

Alternatives rejected so far include a global singleton backend, actor-isolating the renderer, and a
general-purpose compute graph. The first two would serialize or obscure ownership; the last would add
abstraction without serving image processing.
