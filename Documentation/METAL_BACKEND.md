# Metal backend

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

## Runtime objects

`MetalContext` creates one `MTLDevice`, command queue and shader library. With Xcode's build system (and
Swift 6.4's SwiftPM) the `.metal` resources are compiled into the package bundle's `default.metallib`.
An older SwiftPM build system only *copies* them, so there is no compiled library; in that case `MetalContext`
compiles the bundled `.metal` sources at runtime, one library per file, with `#include "…"` of the bundled
headers expanded in place (found by the first GitHub Actions run, which failed with "no default library was
found"). The two paths were tested to give byte-identical output across every kernel, and `swift test
--build-system native` reproduces the old-toolchain situation locally. Runtime compilation adds startup time:
0.7 ms against 0.28 ms for `MetalContext` initialization on a machine with a warm shader cache; a cold
first compile has not been measured. Pipeline-state creation is centralized
and cached by kernel name; operations never create raw Metal infrastructure.

One render uses one command buffer. Standard instrumentation uses a serial compute encoder so
dispatches see preceding writes through Metal's normal hazard tracking. Detailed instrumentation uses
an encoder per pass because Apple GPU timestamps are available at encoder boundaries; this is why
detailed mode is for inspection rather than default-path benchmarking.

## Shader binding convention

- node inputs: `texture(0...n-1)`;
- output: `texture(n)`;
- optional LUT: `texture(n+1)`;
- scalar uniforms: `buffer(0)`;
- constant tables, such as Gaussian weights: `buffer(1)`.

All dispatches cover the exact output grid. Kernels that sample neighborhoods clamp at image
boundaries.

## Blur

Gaussian blur is separable. The direct implementation established correctness; the production path
uses threadgroup tiling and four-output register blocking. Radius-specific weights are normalized on
the CPU and uploaded as constants. Tile dimensions are selected from threadgroup-memory and thread
limits, and unsupported configurations throw instead of silently dispatching an invalid kernel.

This optimization was retained only after benchmark sweeps and byte-for-byte comparisons with the
direct kernels. See [OPTIMIZATION.md](OPTIMIZATION.md).

## CPU/GPU image movement

Native-layout `CGImage`s upload directly from their provider. Other layouts are redrawn by
CoreGraphics into Prism's declared color space and alpha representation. Before CPU readback, a blit
converts GPU-optimized texture contents into a CPU-friendly layout; this removed the original 4K
export bottleneck. The explicit texture API avoids image conversion entirely.

## Caches and memory pressure

- Compute pipelines stay cached for a renderer's lifetime.
- Intermediate textures remain in a budgeted pool and can be purged with `purgeTexturePool()`.
- LUT textures use a budgeted LRU cache and are purged with the same public call.

Metrics expose allocations, reuses, resident bytes, cache hits/misses and LUT uploads. No reported
benchmark number is synthesized from these counters; committed result files contain the measured
runs and environment.

## Current backend limits

There is no explicit cross-queue synchronization for caller-provided textures, no in-flight render
limit, and no fallback from tiled to direct blur on a GPU whose threadgroup limits are insufficient.
The texture API therefore documents that input production must be complete before rendering begins.
