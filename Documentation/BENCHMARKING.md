# Benchmarking Prism

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Benchmarks live in `Benchmarks/` as the `prism-bench` executable. It uses only Prism's
public API, so it measures what a client of the package sees.

```sh
swift build -c release
.build/out/Products/Release/prism-bench --suite all --json Benchmarks/results/<name>.json > Benchmarks/results/<name>.md
```

Never benchmark a debug build; the tool warns if you do. Options: `--suite
ops,pipelines,cold,resources,instrumentation|all`, `--resolutions 1080p,4k,large`,
`--iterations N`, `--warmup N`, `--image PATH` (benchmark a real file), `--quick`.

## What is measured

Every row comes from `ImagePipeline.renderWithMetrics`, so the columns are the engine's own
instrumentation:

| column | meaning |
|---|---|
| total | wall-clock time of the whole `render` call |
| import | `CGImage` → GPU texture (CoreGraphics redraw + upload) |
| encode | CPU time to validate, plan, and encode the command buffer |
| gpu | GPU execution time of the command buffer, from Metal's timestamps |
| export | GPU texture → `CGImage` |
| engine MP/s | megapixels per second of `encode + gpu` only |
| e2e MP/s | megapixels per second of `total` |

`total` is not the sum of the other columns: `gpu` is GPU-timeline time, and `total` also
includes waiting on the GPU, scheduling latency, and untimed bookkeeping.

**Engine vs end-to-end.** While Prism's only image I/O is `CGImage`, `import` and `export`
can dominate `total` (see results). `engine MP/s` isolates the part that is the engine.

## Methodology

- Each case runs `warmup` renders (default 5), then `iterations` measured renders (default 30)
  on one warmed `Renderer`. Reported values are **medians**; JSON also holds min, p95, mean,
  and standard deviation.
- Warm-up absorbs pipeline compilation and texture allocation. **Cold** numbers are a
  separate suite: a fresh `Renderer` per sample (15 samples), reporting first-render time,
  pipelines compiled, and allocations, next to the same pipeline warm. The OS caches
  compiled shader binaries across processes, so cold means cold for the `Renderer`, not
  for the machine.
- Inputs are deterministic synthetic images at 1920×1080, 3840×2160, and 6000×4000
  ("large", a 24 MP camera-sized frame). They are **not photographs**. No Prism kernel
  branches on pixel values, so GPU work depends on dimensions and parameters only; `--image`
  runs a real file for anyone who wants to check.
- Every result file records machine model, CPU, memory, GPU, OS, build configuration,
  thermal state, low-power mode, and the exact command line.

## Interpreting results honestly

- Numbers are from one machine, with whatever else was running. Compare runs from the same
  machine, same thermal state, and treat differences under ~5% as noise (look at stddev/p95
  in the JSON).
- Results in `Benchmarks/results/` are committed *as measured*. A change that is claimed to
  improve performance must include before/after files produced with the same command.
- `detailed` instrumentation encodes differently from `standard` (one encoder per pass), so
  don't use it for performance claims about the default path. The instrumentation suite
  measures what each level costs.

## Result files

| file | what |
|---|---|
| `baseline-0-before-optimization.{md,json}` | The engine as of Phase 6, before any optimization pass |

Optimization results are listed with their own before/after tables in
[OPTIMIZATION.md](OPTIMIZATION.md) once they exist.
