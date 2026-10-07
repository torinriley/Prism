# Prism benchmark

- date: 2026-10-06T23:57:24Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite all --json Benchmarks/results/baseline-0-before-optimization.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Single operations (warm renderer, 30 iterations, 5 warm-up)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Exposure | 1080p | 1 | 4.30 | 0.77 | 0.01 | 0.41 | 2.59 | 4938 | 483 |
| Contrast | 1080p | 1 | 4.22 | 0.77 | 0.01 | 0.39 | 2.57 | 5136 | 491 |
| Saturation | 1080p | 1 | 4.27 | 0.80 | 0.01 | 0.40 | 2.57 | 5057 | 486 |
| Temperature | 1080p | 1 | 4.27 | 0.80 | 0.01 | 0.40 | 2.57 | 5043 | 485 |
| GaussianBlur σ=2 | 1080p | 2 | 4.69 | 0.78 | 0.01 | 0.71 | 2.72 | 2877 | 442 |
| GaussianBlur σ=8 | 1080p | 2 | 5.68 | 0.77 | 0.01 | 1.73 | 2.70 | 1193 | 365 |
| GaussianBlur σ=32 | 1080p | 2 | 10.40 | 0.75 | 0.01 | 6.48 | 2.70 | 320 | 199 |
| Sharpen | 1080p | 3 | 4.64 | 0.75 | 0.01 | 0.79 | 2.61 | 2601 | 447 |
| Resize 0.5× | 1080p | 1 | 2.18 | 0.72 | 0.01 | 0.31 | 0.69 | 6417 | 953 |
| Vignette | 1080p | 1 | 4.29 | 0.81 | 0.01 | 0.40 | 2.60 | 5041 | 484 |
| LUT 33³ | 1080p | 1 | 4.87 | 0.82 | 0.42 | 0.62 | 2.59 | 1995 | 425 |
| Exposure | 4k | 1 | 16.82 | 4.07 | 0.02 | 1.30 | 10.82 | 6279 | 493 |
| Contrast | 4k | 1 | 16.70 | 4.02 | 0.02 | 1.29 | 10.81 | 6318 | 497 |
| Saturation | 4k | 1 | 16.64 | 4.03 | 0.02 | 1.25 | 10.80 | 6535 | 498 |
| Temperature | 4k | 1 | 16.72 | 4.00 | 0.02 | 1.30 | 10.84 | 6268 | 496 |
| GaussianBlur σ=2 | 4k | 2 | 20.29 | 4.26 | 0.03 | 3.13 | 11.75 | 2629 | 409 |
| GaussianBlur σ=8 | 4k | 2 | 23.82 | 4.44 | 0.03 | 6.98 | 11.85 | 1183 | 348 |
| GaussianBlur σ=32 | 4k | 2 | 43.96 | 4.75 | 0.04 | 26.13 | 12.56 | 317 | 189 |
| Sharpen | 4k | 3 | 18.89 | 4.24 | 0.03 | 2.54 | 11.33 | 3229 | 439 |
| Resize 0.5× | 4k | 1 | 8.45 | 4.18 | 0.02 | 0.96 | 2.78 | 8490 | 982 |
| Vignette | 4k | 1 | 17.28 | 4.33 | 0.02 | 1.35 | 11.02 | 6027 | 480 |
| LUT 33³ | 4k | 1 | 18.63 | 4.20 | 0.46 | 2.64 | 10.88 | 2681 | 445 |
| Exposure | large | 1 | 46.55 | 11.10 | 0.02 | 3.05 | 31.77 | 7802 | 516 |
| Contrast | large | 1 | 45.78 | 10.93 | 0.03 | 2.54 | 31.68 | 9350 | 524 |
| Saturation | large | 1 | 45.68 | 10.83 | 0.02 | 2.57 | 31.68 | 9236 | 525 |
| Temperature | large | 1 | 46.33 | 10.85 | 0.02 | 3.07 | 31.88 | 7748 | 518 |
| GaussianBlur σ=2 | large | 2 | 55.16 | 11.08 | 0.02 | 7.69 | 34.88 | 3113 | 435 |
| GaussianBlur σ=8 | large | 2 | 64.74 | 11.07 | 0.02 | 19.96 | 32.95 | 1201 | 371 |
| GaussianBlur σ=32 | large | 2 | 120.03 | 11.21 | 0.02 | 74.19 | 33.82 | 323 | 200 |
| Sharpen | large | 3 | 51.83 | 11.18 | 0.02 | 6.66 | 33.32 | 3589 | 463 |
| Resize 0.5× | large | 1 | 21.43 | 10.61 | 0.02 | 2.03 | 8.24 | 11728 | 1120 |
| Vignette | large | 1 | 47.54 | 11.35 | 0.02 | 3.39 | 32.23 | 7036 | 505 |
| LUT 33³ | large | 1 | 52.05 | 10.95 | 0.47 | 8.26 | 31.99 | 2748 | 461 |

## Multi-stage pipelines (warm renderer)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 6 | 5.35 | 0.79 | 0.02 | 1.34 | 2.73 | 1526 | 387 |
| 10-stage | 1080p | 13 | 6.60 | 0.83 | 0.44 | 2.15 | 2.71 | 800 | 314 |
| 10 per-pixel | 1080p | 10 | 4.63 | 0.80 | 0.02 | 0.74 | 2.61 | 2732 | 448 |
| 5-stage | 4k | 6 | 21.41 | 4.19 | 0.03 | 4.93 | 11.57 | 1674 | 387 |
| 10-stage | 4k | 13 | 24.68 | 4.14 | 0.47 | 8.22 | 11.40 | 954 | 336 |
| 10 per-pixel | 4k | 10 | 18.76 | 4.07 | 0.03 | 3.12 | 10.98 | 2633 | 442 |
| 5-stage | large | 6 | 59.75 | 11.12 | 0.03 | 13.66 | 34.16 | 1753 | 402 |
| 10-stage | large | 13 | 76.53 | 13.22 | 0.55 | 25.71 | 33.84 | 914 | 314 |
| 10 per-pixel | large | 10 | 51.28 | 11.02 | 0.03 | 7.58 | 32.01 | 3152 | 468 |

## Cold vs warm (fresh `Renderer` per cold sample, 15 samples)

| pipeline | res | renderer init ms | cold render ms | cold gpu | cold encode | pipelines compiled | allocations | warm render ms | warm gpu | warm encode |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 0.31 | 7.52 | 1.13 | 0.26 | 6 | 3 | 5.40 | 1.37 | 0.02 |
| 10-stage | 1080p | 0.29 | 9.03 | 1.91 | 0.73 | 9 | 4 | 6.60 | 2.15 | 0.45 |
| 5-stage | 4k | 0.29 | 27.86 | 6.83 | 0.33 | 6 | 3 | 21.20 | 4.97 | 0.03 |
| 10-stage | 4k | 0.29 | 31.24 | 7.94 | 0.84 | 9 | 4 | 24.67 | 8.20 | 0.48 |
| 5-stage | large | 0.30 | 82.65 | 22.79 | 0.40 | 6 | 3 | 59.73 | 13.62 | 0.03 |
| 10-stage | large | 0.30 | 95.03 | 31.10 | 0.94 | 9 | 4 | 69.82 | 23.60 | 0.49 |

## Texture allocation behavior

| pipeline | res | passes | live textures | logical | render 1 allocs | render 2 allocs | render 2 reuses | peak texture MiB | resident after MiB |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 6 | 3 | 7 | 3 | 0 | 3 | 24.3 | 24.3 |
| 10-stage | 1080p | 13 | 4 | 14 | 4 | 0 | 4 | 32.4 | 32.4 |
| 10 per-pixel | 1080p | 10 | 3 | 11 | 3 | 0 | 3 | 24.3 | 24.3 |
| 5-stage | 4k | 6 | 3 | 7 | 3 | 0 | 3 | 97.1 | 97.1 |
| 10-stage | 4k | 13 | 4 | 14 | 4 | 0 | 4 | 129.5 | 129.5 |
| 10 per-pixel | 4k | 10 | 3 | 11 | 3 | 0 | 3 | 97.1 | 97.1 |
| 5-stage | large | 6 | 3 | 7 | 3 | 0 | 3 | 280.6 | 280.6 |
| 10-stage | large | 13 | 4 | 14 | 4 | 0 | 4 | 374.1 | 374.1 |
| 10 per-pixel | large | 10 | 3 | 11 | 3 | 0 | 3 | 280.6 | 280.6 |

## Instrumentation overhead (5-stage pipeline)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage @off | 1080p | 6 | 5.29 | 0.00 | 0.00 | 0.00 | 0.00 | inf | 392 |
| 5-stage @standard | 1080p | 6 | 5.22 | 0.85 | 0.02 | 1.09 | 2.82 | 1863 | 397 |
| 5-stage @detailed | 1080p | 6 | 5.45 | 0.80 | 0.04 | 1.34 | 2.79 | 1509 | 381 |
| 5-stage @off | 4k | 6 | 21.05 | 0.00 | 0.00 | 0.00 | 0.00 | inf | 394 |
| 5-stage @standard | 4k | 6 | 20.93 | 3.83 | 0.03 | 4.88 | 11.55 | 1691 | 396 |
| 5-stage @detailed | 4k | 6 | 21.47 | 4.08 | 0.07 | 4.97 | 11.63 | 1648 | 386 |
| 5-stage @off | large | 6 | 59.86 | 0.00 | 0.00 | 0.00 | 0.00 | inf | 401 |
| 5-stage @standard | large | 6 | 59.82 | 11.12 | 0.03 | 13.64 | 34.41 | 1756 | 401 |
| 5-stage @detailed | large | 6 | 59.66 | 10.97 | 0.07 | 13.65 | 34.35 | 1749 | 402 |

wrote Benchmarks/results/baseline-0-before-optimization.json
