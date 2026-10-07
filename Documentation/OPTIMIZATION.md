# Optimization log

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Rule: measure, find the bottleneck, change one thing, measure again, verify correctness,
record the result here. Baseline: `Benchmarks/results/baseline-0-before-optimization.md`
(Apple M5, macOS 27.0.1, release build; synthetic inputs; medians of 30 renders).

The final precision comparison is `Benchmarks/results/after-5-precision.md`.

## Baseline findings (before any optimization)

All numbers below are medians from the baseline file.

### 1. Image conversion dominates end-to-end time

For a single per-pixel operation at 4K (3840×2160):

| stage | ms | share of `total` (16.7) |
|---|---:|---:|
| GPU (Exposure) | 1.30 | 8% |
| import (`CGImage` → texture) | 4.07 | 24% |
| export (texture → `CGImage`) | 10.82 | 65% |

`export` is about 8× the GPU work and scales linearly with pixel count (2.6 ms at 1080p,
31.7 ms at 24 MP, ≈ 3 GB/s). That is far below memory bandwidth, so the cost is the number
of full-image copies in the `CGImage` export path (read into an array, copy into `Data`,
wrap in a `CGImage`), not the GPU. Every operation's end-to-end throughput is therefore
capped around 500 MP/s while its engine throughput (encode + GPU) is 5,000–9,000 MP/s.
Resize 0.5× looks fast end-to-end only because its output is a quarter the size.

→ The `MTLTexture` input/output path (required by the brief anyway) removes this cost for
clients that already hold textures; the `CGImage` path should lose its redundant copies.

### 2. Per-pixel passes: ~0.2 ms each at 4K once the GPU is busy

> **Correction (added after the fusion measurements below).** The original text of this finding
> claimed per-pixel passes are memory-bound at "≈ 0.25 ms fixed + ≈ 100 GB/s" and that fusing
> them would cut GPU time "in proportion to the pass count". That estimate was derived from
> single-operation timings at three image sizes, which mix per-pass cost with a large
> per-command-buffer fixed cost, and it was wrong. The `alu` diagnostic shows the real shape:

A single per-pixel pass costs ≈ 0.7–1.2 ms at 4K when it is the only work in a command buffer,
but additional passes in the same buffer add only ≈ 0.19 ms each (steady-state slope of
20→40 unfused Contrast passes: 4.7 → 8.7 ms). So a first-order model is
**≈ 1–1.6 ms fixed per command buffer (not attributable to any kernel; consistent with the GPU
starting from an idle clock) + ≈ 0.2 ms per extra pass at 4K.** Ten per-pixel passes cost
3.1 ms at 4K, not 13 ms.

### 3. Gaussian blur is bound by texture fetches, linear in radius

GPU time: σ=2 → 3.1 ms, σ=8 → 7.0 ms, σ=32 → 26.1 ms at 4K. Dividing taps by time gives a
constant ≈ 120 G tap-fetches/s across radii, so cost is proportional to the number of
fetches, not ALU work. σ=32 at 4K is 26 ms, far outside real-time budgets.

→ Cache each row/column tile in threadgroup memory so each texel is fetched once per pass
instead of 2r+1 times. Hardware-bilinear tap pairing was considered and rejected for now:
sampler weight precision is limited (typically 8 fractional bits), which risks the 1 LSB
reference tolerance.

### 4. LUT grading pays a fixed CPU cost every render

LUT 33³ has `encode` = 0.42–0.47 ms against 0.01–0.03 ms for every other operation, at every
resolution, because the 3D LUT texture is rebuilt and re-uploaded per render. In the
10-stage pipeline this is nearly all of its 0.44–0.55 ms encode time.

→ Cache LUT textures per renderer.

### 5. Things that are fine

- **Instrumentation overhead is small.** The 5-stage pipeline's total differs by < 1.5%
  across `off` / `standard` / `detailed` at every size (e.g. 4K: 21.05 / 20.93 / 21.47 ms;
  24 MP: 59.86 / 59.82 / 59.66 ms), within run-to-run noise. `detailed` doubles CPU encode
  time (0.03 → 0.07 ms), which is negligible next to GPU time.
- **Texture reuse works.** Every pipeline allocates textures only on its first render
  (3 for the 5-stage and per-pixel pipelines, 4 for the 10-stage one) and none afterward. A
  one-texture-per-pass scheme would need 7 / 14 / 11.
- **Cold-start cost is small.** `Renderer` init is 0.3 ms and a cold pipeline compile is ≈ 0.04
  ms each (encode 0.26 ms cold vs 0.02 ms warm for six pipelines). The larger cold-vs-warm gap
  (e.g. 4K: 27.9 vs 21.2 ms) is mostly first-touch of 97 MB of newly allocated textures,
  which the pool avoids from the second render on.

## Planned work, in priority order

| # | change | evidence | expected effect |
|---|---|---|---|
| 1 | Graph optimizer; identity and dead-node elimination | brief §22; identity ops still cost a full pass | removes whole passes |
| 2 | Per-pixel pass fusion | finding 2 (corrected) | fewer passes/textures; ~3× cheaper cheap ops; no general speedup (done) |
| 3 | `MTLTexture` in/out + cheaper `CGImage` conversion | finding 1 | removes the dominant cost (done: 3–4× end to end) |
| 4 | Threadgroup-tiled, register-blocked blur | finding 3 | 1.3–2.3× faster blur (done, measured) |
| 5 | LUT texture cache | finding 4 | LUT encode 0.45 → 0.02–0.04 ms (done, measured) |

Each item gets its own before/after section below as it lands.

## Results

### 1. Graph optimizer: identity and dead-node elimination

Files: `Benchmarks/results/after-1-identity-dce.{md,json}` against the baseline, same machine,
same command shape (`--suite optimizer,pipelines`).

**What changed.** Operations now always emit their passes, marking them `isIdentity` when
their parameters are neutral (`Exposure(0)`, `Contrast(1)`, `Saturation(1)`, `Temperature(0)`,
`Vignette(0)`, `GaussianBlur(0)`, `Sharpen(0)`, a same-size `Resize`, `LUTGrade(intensity: 0)`).
`GraphOptimizer` runs two passes before planning: identity elimination (rewires consumers to
the pass's first input, only when the output descriptor is unchanged) and dead-node
elimination. `Sharpen(amount: 0)` shows them composing: its combine step is an identity, and
the blur passes it leaves unread are then dead. Both can be switched off with
`Renderer(optimizations:)`.

**Pipelines modelling an editing UI with controls at their defaults** (medians, ms):

| pipeline | res | passes off → on | GPU off → on | total off → on |
|---|---|---:|---:|---:|
| 6 neutral stages | 4k | 9 → 0 | 3.31 → 0.00 | 19.24 → 6.73 |
| 6 neutral stages | large | 9 → 0 | 8.85 → 0.00 | 53.21 → 18.92 |
| 1 active + 5 neutral | 4k | 9 → 1 | 3.50 → 1.31 | 19.39 → 17.26 |
| 1 active + 5 neutral | large | 9 → 1 | 8.93 → 3.03 | 53.71 → 47.74 |
| blur σ=8 + 5 neutral | 4k | 9 → 2 | 9.37 → 7.04 | 25.95 → 23.87 |
| blur σ=8 + 5 neutral | large | 9 → 2 | 26.91 → 20.27 | 73.04 → 66.76 |

The GPU column is the optimizer's effect: GPU time falls in proportion to the passes removed
(the 1080p rows show the same pattern). For pipelines with no neutral stages
(`pipelines` suite) nothing changes within noise: GPU times are the same, end-to-end totals
differ by −0.4% to +3% (stddev 0.7–3.9 ms), and CPU encode grows by about 0.01 ms, which is
the cost of running the optimizer on every render.

**An unexpected finding — read this before trusting the `total` column for "6 neutral
stages".** The `export` column drops from 11.2 ms to 2.4 ms at 4K in that case, far more than
removing GPU work explains. With nothing to run, the "output" is the source texture, which the
CPU wrote itself; reading back a texture the GPU has *written* is ~4–5× slower than reading one the CPU
uploaded. That drop is not an optimizer win; it is evidence that GPU-written textures have a
layout that is expensive for the CPU to read (see finding 1 above). It makes the export path
the top target for item 3, and a likely candidate is
`MTLBlitCommandEncoder.optimizeContentsForCPUAccess` or creating pooled textures with
`allowGPUOptimizedContents = false`; both are to be measured, not assumed.

**Correctness.** Optimized and unoptimized pipelines produce bit-identical output (test:
`sameResult`, 15 passes → 6). A symbolic check over 500 random DAGs verifies the output's
expression is unchanged, the result validates, no flagged identity survives, and re-optimizing
is a no-op. Mutation checks confirmed the tests fail if source textures are not re-keyed after
renumbering or if an identity is removed when its output descriptor differs.

### 2. Per-pixel pass fusion — implemented, verified, measured (modest effect)

**What changed.** Each per-pixel color operation (Exposure, Contrast, Saturation,
Temperature, Vignette) is now a single shared Metal function (`Pointwise.h`). The standalone
kernels and the new `prism_pointwise_chain` kernel both call it, so the math has one
definition. `PointwiseFusion` (a graph pass, run after identity and dead-node elimination)
merges each run of such passes into one chain pass: one read and one write per pixel for the
whole run. A run continues only while each node has exactly one consumer, is not the graph
output, and keeps its size and format; branches, spatial passes and LUTs end it. Runs longer
than 32 split into segments. It is part of `OptimizationOptions.all` and can be turned off
with `.pointwiseFusion` omitted.

**Numerical effect: fusion is not bit-identical to the unfused chain, by design.** It skips
the 8-bit rounding between operations. Measured against a Double-precision chain with no
intermediate rounding (the ideal result), for the 10-operation chain in `FusionTests`:

| image | fused vs exact | unfused vs exact | fused vs unfused |
|---|---:|---:|---:|
| 7×5 | 0 LSB | 2 LSB | 2 LSB |
| 67×41 | 0 LSB | 3 LSB | 3 LSB |
| 256×129 | 1 LSB | 3 LSB | 3 LSB |

So fusion removes the accumulated quantization error rather than adding error. A
single operation through the chain kernel is bit-identical to its own kernel (10 parameter
sets tested), so any difference comes only from skipped rounding.

**Verification.** 135 tests pass; TSan clean. Structure tests cover runs, branches,
duplicate inputs, the output boundary, size changes, segmentation at 32, idempotence, and
500 random DAGs checked symbolically. Mutation checks (chain kernel vignette parameters
swapped; single-consumer rule removed; operations packed in reverse order) failed 3, 397
and 237 assertions respectively and were reverted.

**Speed.** Files: `Benchmarks/results/after-2-fusion.{md,json}` (suites `fusion,pipelines`) and
`diagnosis-alu-vs-bandwidth.{md,json}` (suite `alu`, 4K only). Same machine as the baseline, run
after an earlier attempt was discarded because Blender was rendering. The machine was quiet
for `after-2-fusion` (import/export match the baseline) but background daemons kept the load
average at 4–5 during the diagnosis run; two runs of it agreed within ~10%.

Cost per additional identical operation at 4K, from the slope between 20 and 40 operations
(GPU ms per operation; fixed per-buffer cost excluded):

| operation | unfused (one pass each) | fused |
|---|---:|---:|
| Contrast | 0.19 | 0.065 |
| Exposure | 0.21 | 0.185 |

- For cheap operations (Contrast, Saturation) fusion works as designed: each extra operation
  is ~3× cheaper because it no longer reads and writes the whole image.
- For operations that use `pow` (Exposure, Temperature, Vignette: six `pow`s per pixel for the
  sRGB decode and encode) fusion saves only ~12% per operation, because arithmetic, not memory,
  is the limit. Fusing cannot remove those `pow`s.

Effect on the benchmark pipelines (median GPU ms / total ms, baseline → after optimizer →
after fusion; "passes" are GPU passes before → after fusion):

| pipeline | res | passes | GPU ms | total ms |
|---|---|---:|---|---|
| 10 per-pixel | 1080p | 10 → 1 | 0.74 / 0.73 / 0.57 | 4.63 / 4.67 / 4.48 |
| 10 per-pixel | 4k | 10 → 1 | 3.12 / 3.26 / 2.58 | 18.76 / 19.08 / 18.05 |
| 10 per-pixel | large | 10 → 1 | 7.58 / 7.86 / 8.38 | 51.28 / 52.75 / 52.33 |
| 5-stage | 4k | 6 → 4 | 4.93 / 4.96 / 5.49 | 21.41 / 21.32 / 22.58 |
| 10-stage | 4k | 13 → 8 | 8.22 / 8.24 / 7.75 | 24.68 / 24.92 / 23.94 |
| 10-stage | large | 13 → 8 | 25.71 / 24.49 / 22.37 | 76.53 / 76.34 / 72.81 |

**Honest summary:** fusion removes passes and reduces memory (a 10-operation per-pixel
pipeline needs 2 textures instead of 3), and it makes long chains of cheap operations about 3×
cheaper per operation. But on the pipelines measured, GPU time changes by roughly −23% to +10%
(mostly within run-to-run noise) and end-to-end time by −5% to +5%, because end-to-end time is
dominated by image import/export (finding 1). **I do not claim a general speedup from fusion.**
Its value is structural (fewer passes, fewer intermediate textures, less memory traffic) and
it will matter more on the texture-in/texture-out path, where conversions don't mask it.

**What would reduce the per-operation cost of the pow-heavy operations** (not done; each would
need its own measurement): keeping color in linear light between adjacent linear-light
operations (Exposure, Temperature, Vignette) so the sRGB round trip happens once per run instead
of once per operation; or a cheaper sRGB curve. Since the typical editing chain interleaves
linear and encoded operations, the first would help only some pipelines.

**Where the engine's time actually goes (4K, measured):** blur is the largest GPU cost by far
(σ=8: ~7 ms; σ=32: ~26 ms) against ~0.2 ms per per-pixel pass, and image conversion
(~15 ms) dwarfs all GPU work. Items 3 and 4 are therefore the ones that can matter.

### 3. Image conversion and the `MTLTexture` path

Files: `Benchmarks/results/after-3-conversions.{md,json}` (suites `ops,pipelines,texture`); machine
84% idle before and after the run. Baseline: `baseline-0-before-optimization`.

**Diagnosis first.** A release-mode probe at 4K (RGBA8) separated the two hypotheses from
finding 1:

| `getBytes` of a 4K texture | ms |
|---|---:|
| written by the CPU (`replace`) | 1.7 |
| written by the GPU, default | **12.0** |
| written by the GPU, `allowGPUOptimizedContents = false` | 3.6 |
| written by the GPU, then a blit `optimizeContentsForCPUAccess` | **1.5** |

The cost was the GPU's optimized (tiled/compressed) layout, not redundant copies: building
`Data` from the bytes was only 0.6 ms of a 12.3 ms export. `allowGPUOptimizedContents = false` was
rejected because it would change the layout of every pooled texture the kernels read and write,
risking kernel speed to fix a CPU-readback problem.

**Changes.**
1. When the result is read back on the CPU (the `CGImage` path), the command buffer ends with a
   blit `optimizeContentsForCPUAccess` on the output. GPU-only consumers (the texture path) skip it.
2. Export reads the pixels once, straight into a malloc'd buffer the `CGImage` owns (previously: a
   zero-filled array, then a `Data` copy).
3. Import of an image already in Prism's native layout (8-bit RGBA, premultiplied last, sRGB)
   uploads straight from the image's backing store, skipping the CoreGraphics redraw. Other
   layouts still redraw (see COLOR.md).
4. New public API: `pipeline.render(texture, into:)` / `renderWithMetrics`, taking and returning
   `MTLTexture` with no CPU round trip. A supplied destination replaces the output node's pooled
   slot, so the last pass writes straight into it.

**`CGImage` path, before → after** (median ms; single operations; every row's import/export columns
are independent of the later optimizer and fusion changes):

| case | res | import | export | total | end-to-end MP/s |
|---|---|---:|---:|---:|---:|
| Exposure | 1080p | 0.77 → 0.43 | 2.59 → 0.35 | 4.30 → 1.54 | 483 → 1349 |
| Exposure | 4k | 4.07 → 1.83 | 10.82 → 1.60 | 16.82 → 4.61 | 493 → 1800 |
| Exposure | large | 11.10 → 5.05 | 31.77 → 4.88 | 46.55 → 13.18 | 516 → 1821 |
| GaussianBlur σ=8 | 4k | 4.44 → 1.85 | 11.85 → 1.59 | 23.82 → 11.16 | 348 → 743 |
| Sharpen | 4k | 4.24 → 1.97 | 11.33 → 1.67 | 18.89 → 7.06 | 439 → 1175 |
| LUT 33³ | 4k | 4.20 → 1.97 | 10.88 → 1.68 | 18.63 → 6.44 | 445 → 1287 |

Export is 6–7× faster and import about 2.2× faster; end-to-end throughput of a per-pixel operation
is 3.4–3.7× higher. The `GPU` column for these rows is not comparable to the baseline: it now
includes the layout blit (a fraction of a millisecond at 4K) and the GPU sees different idle gaps.

**Texture in / texture out** (destination reused every frame; no import or export):

| pipeline | res | total ms | gpu ms | `CGImage` total ms (baseline → now) |
|---|---|---:|---:|---:|
| 10 per-pixel (fused to 1 pass) | 4k | 1.75 | 1.51 | 18.76 → 5.66 |
| 5-stage | 4k | 4.62 | 4.40 | 21.41 → 9.97 |
| 10-stage | 4k | 8.36 | 7.66 | 24.68 → 12.48 |
| 5-stage | large | 13.10 | 12.88 | 59.75 → 25.20 |
| Exposure | 4k | 0.51 | 0.33 | 16.82 → 4.61 |
| GaussianBlur σ=8 | 4k | 7.20 | 6.98 | 23.82 → 11.16 |

Total time on the texture path is dominated by GPU time (CPU encode is 0.01–0.05 ms, 0.45 ms for
pipelines with a LUT). **A 5-stage pipeline at 4K runs in 4.6 ms (about 215 fps) texture-to-texture**,
so real-time processing of 4K frames is feasible for pipelines of that size; the 10-stage pipeline
(8.4 ms) fits a 60 fps budget; a σ=8 blur alone is 7.2 ms.

**Two things these numbers show that were hypotheses before:**
- *Idle GPU gaps inflate per-pass cost.* A single Exposure at 4K reports 0.33 ms of GPU time here
  versus 1.3 ms in the baseline, because the texture suite submits renders back to back while the
  baseline's `CGImage` renders were separated by ~15 ms of CPU conversion. This supports the
  "fixed cost per command buffer from an idle GPU" explanation of finding 2's correction, though I
  have not confirmed it against a GPU clock reading. GPU times from the two suites should not be
  compared directly.
- *Blur and LUT are now the outliers.* On the texture path a σ=8 blur costs 7.0 ms against 0.33 ms
  for Exposure, and LUT 33³ costs 1.98 ms against 0.54 ms for Contrast even though its GPU time
  is only 1.31 ms: its CPU encode is 0.45 ms because the LUT texture is rebuilt every render.
  Those are items 4 and 5.

**Correctness.** 151 tests pass. The texture path is bit-identical to the `CGImage` path for the
same pipeline; `bgra8Unorm` matches `rgba8Unorm` after channel swap; destination reuse leaks nothing
between frames (tested with different pipelines into one texture); the destination may share a
slot with earlier passes without corrupting the result; unusable inputs and destinations are
rejected (usage, format, size, same-as-input, multisample, no `.shaderRead`). Mutation checks
(skipping the no-op copy, allowing destination == input, wrong slot for the destination) failed 2,
2 and 4 assertions respectively. Import layouts are tested: native fast path equals the redraw path
byte for byte, padded rows, BGRA, RGBX, straight alpha, greyscale, and Display P3.

**Remaining limits.** Cross-queue synchronization is the caller's job (the input must be complete
before the call; documented). 16-bit float textures are rejected for now. A texture-path caller who
reads the result on the CPU should add their own `optimizeContentsForCPUAccess` blit; Prism only
does it for its `CGImage` output.

### 4. Gaussian blur: threadgroup tiling and register blocking

**Baseline** (`blur-0-before.{md,json}`, texture path, 4K, machine ~85% idle, GPU ms): σ=1: 1.30,
2: 2.07, 4: 4.06, 8: 7.70, 16: 13.72, 32: 26.38, 64: 52.38. Cost is linear in σ, i.e. in the number of
tap fetches (finding 3).

**Step 1: tile in threadgroup memory** (`blur-1-tiled-v1`). Each threadgroup loads its row/column
segment plus a halo into threadgroup memory once; threads read taps from there. Result: only
1.1–1.35× for σ ≤ 16 (σ=8: 7.70 → 5.71 ms). Fetches were part of the cost, not all of it: each tap
still did a threadgroup read, a weight load and four FMAs.

**Step 2: register blocking** (`blur-2-tiled-v2`). Each thread computes four adjacent outputs from
one sliding window over the tile, so each tile read feeds four accumulators. Weights are padded
with three zeros on each side so the four accumulators share one unconditional loop. Result: σ=8:
5.71 → 3.67 ms (2.1× the original), σ=4: 4.06 → 1.92.

**Step 3: tune what was a guess.** Swept at 4K (GPU ms; σ = 1, 2, 4, 8, 16, 32, 64):

| configuration | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---:|---:|---:|---:|---:|---:|---:|
| vertical threads 4, tile ≤ σ=21 | 1.62 | 1.37 | 2.28 | 4.82 | 11.23 | 26.20 | 52.24 |
| vertical threads 8, tile ≤ σ=21 | 1.05 | 1.24 | 1.92 | 3.67 | 8.25 | 26.29 | 51.99 |
| vertical threads 16, tile ≤ σ=21 | 0.98 | 1.21 | 1.86 | 3.30 | 6.36 | 26.17 | 52.09 |
| vertical threads 32, tile ≤ σ=21 | 0.98 | 1.19 | 1.85 | 3.28 | 6.14 | 26.24 | 52.46 |
| vertical threads 8, tile all σ | 1.05 | 1.24 | 1.92 | 3.68 | 8.25 | 20.34 | 69.10 |
| **vertical threads 16, tile all σ (shipped)** | 0.98 | 1.21 | 1.86 | 3.33 | 6.38 | **15.47** | **40.88** |

(The sweep was run from the command line at ~80% machine idle; its console output is the source,
not a saved file. Rows 1–5 used a temporary environment-variable hook, since removed.) 16 and 32
threads were equally fast, so 16 shipped (smaller threadgroups). Tiling beats the direct kernel at
every radius including σ=64, so every radius uses it. **Net at 4K: σ=2: 1.7×, σ=4: 2.2×, σ=8: 2.3×,
σ=16: 2.2×, σ=32: 1.7×, σ=64: 1.3×.** The gain shrinks at large σ because the halo (2·radius
extra texels per tile) grows relative to the tile, and the vertical tile must narrow to fit
32 KiB of threadgroup memory (at σ=64 only 4 columns × 16 threads per group).

**Correctness.** The tiled kernels use the same taps in the same order as the direct kernels, and a
test asserts their output is *identical* (byte for byte) across 13 image sizes (1×1 to 640×480,
including widths and heights that are not multiples of 4 or of the tile) and 7 radii (σ 0.3 to 64).
They also match the Double-precision reference within 1 LSB, including a halo larger than the whole
image (2×2 at σ=64). Mutation checks (wrong weight offset, unclamped halo) fail 184 and 192
assertions. The direct kernels remain in the shader library as the test oracle.

**Limits.** A GPU that cannot provide the tile's threadgroup memory or thread count makes the
render throw rather than fall back (every Apple GPU provides 32 KiB; the check exists for safety).
Tile shapes were tuned on one GPU (Apple M5); other GPUs may prefer different shapes.

**Final measurement** (`after-4-blur-lut.{md,json}`, suites `blur,texture,ops`; machine 86.9% idle
before and 88.3% after). GPU ms, texture path, untiled baseline → shipped:

| σ | 1080p | 4K | 24 MP |
|---|---|---|---|
| 1 | 1.31 → 0.26 (5.0×) | 1.30 → 0.99 (1.3×) | 3.77 → 2.89 (1.3×) |
| 2 | 1.05 → 0.30 (3.6×) | 2.07 → 1.21 (1.7×) | 5.99 → 3.58 (1.7×) |
| 4 | 1.18 → 0.47 (2.5×) | 4.06 → 1.86 (2.2×) | 10.78 → 5.39 (2.0×) |
| 8 | 1.69 → 0.83 (2.0×) | 7.70 → 3.30 (2.3×) | 20.18 → 9.55 (2.1×) |
| 16 | 3.27 → 1.59 (2.1×) | 13.72 → 6.38 (2.1×) | 38.76 → 18.47 (2.1×) |
| 32 | 6.44 → 3.85 (1.7×) | 26.38 → 15.47 (1.7×) | 76.75 → 44.85 (1.7×) |
| 64 | 12.83 → 10.19 (1.3×) | 52.38 → 40.88 (1.3×) | 152.24 → 118.69 (1.3×) |

The 4K column reproduces the sweep above to within 0.01 ms (3.30, 6.38, 15.47, 40.88), so the sweep
figures are confirmed by a saved file. The gain is ~2× for σ = 2–16 at 4K and above, 1.7× at σ=32 and
1.3× at σ=64. Small radii at small sizes show larger ratios (σ=1 at 1080p: 5×) but on sub-millisecond
times where a fixed per-buffer cost dominates; the 4K and 24 MP rows are the reliable ones. The
tile shapes were tuned on one GPU (Apple M5).

End-to-end effect on texture-path pipelines (total ms, before the blur and LUT work → now):

| pipeline | 1080p | 4K | 24 MP |
|---|---|---|---|
| 5-stage (with σ=4 blur) | 1.29 → 0.88 | 4.62 → 2.82 | 13.10 → 7.72 |
| 10-stage (blur, sharpen, LUT) | 2.54 → 1.61 | 8.36 → 5.78 | 23.12 → 16.35 |
| GaussianBlur σ=8 | 1.92 → 1.04 | 7.20 → 3.51 | 20.69 → 9.77 |
| Sharpen | 0.72 → 0.56 | 2.46 → 1.70 | 6.73 → 4.62 |

### 5. LUT texture cache

Finding 4: LUT passes cost 0.4–0.5 ms of CPU every render because the 3D texture was rebuilt and
uploaded each time. `LUT3D` now has an identity (a `UUID` assigned at creation; copies of a value
share it), and each `Renderer` keeps a small LRU cache (64 MiB budget) of LUT textures keyed by that
identity. A miss builds the texture under the lock, so concurrent first uses upload once. A LUT too
large for the budget is used but not kept. Evicting a texture a command buffer is still using is
safe because encoders retain their resources until the buffer completes. `purgeTexturePool()` also
clears it, and `RendererStatistics` reports `lutTextureUploads`, `lutTextureHits`, `cachedLUTBytes`.

**Verified:** 8 tests (one upload across repeated renders; two passes and copies of one LUT share a
texture; different LUTs of the same size stay distinct; LRU eviction order; oversize LUTs;
32 concurrent renders upload once; purging while renders are in flight stays correct; the texture
path uses the same cache). Mutations (all LUTs share one id; cache never hits) fail 16 and 9
assertions.

**Measured** (`after-4-blur-lut`, same run as the blur results; `texture` and `ops` suites), CPU encode
time of a single LUT 33³ pass, median ms:

| path | 1080p | 4K | 24 MP |
|---|---|---|---|
| `CGImage`, baseline → now | 0.422 → 0.022 | 0.457 → 0.032 | 0.470 → 0.044 |
| texture, before cache → now | 0.409 → 0.006 | 0.446 → 0.021 | 0.451 → 0.022 |

Encode time is now in line with every other operation (0.01–0.05 ms), a 10–70× reduction. The
10-stage texture pipeline's encode time falls from 0.44–0.47 ms to 0.043–0.046 ms. At 4K, a LUT pass on
the texture path takes 1.52 ms total (was 1.98 ms); a Contrast pass takes 0.51 ms, so the remaining
cost of a LUT pass is its GPU time (8 texture reads and trilinear interpolation per pixel), not CPU.
