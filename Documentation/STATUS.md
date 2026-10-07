# Prism — implementation status

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Updated October 6, 2026. This file describes the repository as it exists; measured claims link to committed benchmark output.

| Area | Status |
|---|---|
| Engine phases 1–7 | Complete |
| 8-bit and `rgba16Float` precision | Complete and measured |
| Prism Studio + GPU inspector | Complete |
| Tests | 182 tests in 22 suites passing |
| Release build | Passes; no Prism compiler warnings |
| Dependencies | Apple frameworks only |
| Documentation | README plus architecture, graph, backend, color, benchmarking and optimization docs |

## Implemented

- Swift 6 package for macOS 14+ and iOS 17+.
- Async `CGImage` and `MTLTexture` rendering with custom Metal kernels.
- Explicit validated DAG, deterministic topological order and lifetime analysis.
- Identity/dead-node elimination and compatible pointwise fusion.
- Texture pooling, resource-slot reuse, pipeline-state cache and LUT texture LRU cache.
- Exposure, Contrast, Saturation, Temperature, GaussianBlur, Sharpen, Resize, Vignette and LUT grade.
- `rgba8Unorm` and `rgba16Float` storage; float32 shader arithmetic.
- Three instrumentation levels, signposts, per-pass GPU timestamps and renderer lifetime statistics.
- Reproducible release benchmark executable and committed before/after results.
- macOS Prism Studio with loading, drag/drop, real-time parameters, before/after, precision selection, export and a graph/resource/pipeline inspector.

## Verification

- Every operation has a Double-precision CPU reference.
- Random DAG tests cover optimizer semantics and resource aliasing.
- Concurrent rendering, cache contention, cancellation, texture ownership and precision mixing are tested.
- Direct and optimized blur kernels are byte-identical for the tested 8-bit domain.
- Thread Sanitizer and Address Sanitizer have run clean.
- Debug and release builds include the engine, benchmark executable and Studio.

## Measured optimization work

The complete record is [OPTIMIZATION.md](OPTIMIZATION.md). Highlights on the Apple M5 test machine:

- layout-aware readback reduced 4K Exposure end-to-end time from 16.8 to 4.6 ms;
- tiled/register-blocked σ=8 blur reduced 4K GPU time from 7.70 to 3.30 ms;
- LUT caching reduced recurring LUT encode cost from 0.42–0.47 to 0.02–0.04 ms;
- half-float reduced a 20-stage chain's measured error from about 10.8 to 2.3 8-bit LSBs when fusion was disabled; fusion plus half-float reduced it below 0.6 LSB.

See `Benchmarks/results/after-5-precision.md` for the precision cost. At 4K, the five-stage texture pipeline measured 3.13 ms in 8-bit and 3.51 ms in float16; the same CGImage route measured 7.25 and 14.19 ms because float image conversion dominates.

## Explicit limitations

- Color is not advertised as professional HDR/wide-color output. See [COLOR.md](COLOR.md).
- The public graph remains pipeline-oriented; no public composite operation is exposed.
- URL, Data and CIImage helpers are not provided.
- Bilinear resize can alias during large downscales.
- Callers own cross-queue synchronization for texture input.
- No in-flight render limit is imposed, so peak memory follows concurrency.
- Performance has been measured on one Apple GPU generation.
- ImageIO's PNG writer handles a half-float `CGImage` badly (8-bit output; up to 11 LSB error on partly
  transparent pixels; cause not identified). Prism Studio avoids it by converting to 16-bit integer first
  (tested); anyone exporting a `.high` result themselves should do the same. See [COLOR.md](COLOR.md).
- At 24 MP the float16 texture path's wall time exceeds its GPU time by about 5 ms (e.g. 13.65 vs
  8.57 ms for the 5-stage pipeline); reproducible, cause not understood. See [OPTIMIZATION.md](OPTIMIZATION.md).
- The README screenshot is a cold first frame (pipelines compiling, no texture reuse); it should be retaken
  after moving a slider. Prism Studio runs at `.detailed` instrumentation, which its inspector now states.
- **Shader packaging.** A toolchain whose SwiftPM only copies `.metal` files (the GitHub-hosted runner's) has no
  precompiled library; Prism then compiles the bundled sources at runtime. The two paths give byte-identical
  output (tested), but the runtime path adds startup time (0.7 ms vs 0.28 ms warm; cold not measured) and has been
  exercised in CI only through the first failing run's diagnosis plus a local `--build-system native` run.
- **iOS:** the `Prism` library compiles for iOS devices and the iOS Simulator (verified with
  `xcodebuild -scheme Prism -destination 'generic/platform=iOS'` and `…'iOS Simulator'`). It has never been
  *run* on iOS: tests, benchmarks and measurements are macOS-only. Building the whole package for iOS
  fails because Prism Studio imports AppKit; the library product is unaffected. (An earlier revision did
  not compile for iOS at all: it used `MTLStorageMode.managed`, which iOS lacks. That path is now
  macOS-only.)
- SwiftPM/Xcode 27 may print `missing creator for mutated node` for the generated resource bundle; this is a SwiftPM build-system warning rather than a Prism source warning.

## Optional future work

These are extensions, not unfinished claims: public compositing, higher-quality resize methods, additional interop conveniences, wider hardware benchmarking and an in-flight scheduler.
