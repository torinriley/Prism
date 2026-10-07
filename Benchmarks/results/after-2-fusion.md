# Prism benchmark

- date: 2026-10-07T01:16:59Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite fusion,pipelines --json Benchmarks/results/after-2-fusion.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Multi-stage pipelines (warm renderer)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 4 | 5.87 | 0.88 | 0.03 | 1.58 | 3.06 | 1293 | 354 |
| 10-stage | 1080p | 8 | 6.46 | 0.89 | 0.47 | 1.92 | 2.68 | 869 | 321 |
| 10 per-pixel | 1080p | 1 | 4.48 | 0.84 | 0.03 | 0.57 | 2.62 | 3488 | 463 |
| 5-stage | 4k | 4 | 22.58 | 4.30 | 0.05 | 5.49 | 11.83 | 1496 | 367 |
| 10-stage | 4k | 8 | 23.94 | 4.01 | 0.49 | 7.75 | 11.18 | 1007 | 347 |
| 10 per-pixel | 4k | 1 | 18.05 | 4.06 | 0.04 | 2.58 | 10.86 | 3161 | 460 |
| 5-stage | large | 4 | 58.53 | 11.10 | 0.05 | 13.00 | 33.77 | 1840 | 410 |
| 10-stage | large | 8 | 72.81 | 13.42 | 0.58 | 22.37 | 33.58 | 1046 | 330 |
| 10 per-pixel | large | 1 | 52.33 | 11.16 | 0.05 | 8.38 | 31.83 | 2846 | 459 |

## Per-pixel fusion: off vs on

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 per-pixel [fusion off] | 1080p | 2 | 4.41 | 0.79 | 0.02 | 0.46 | 2.65 | 4338 | 471 |
| 2 per-pixel [fusion on] | 1080p | 1 | 4.30 | 0.78 | 0.02 | 0.40 | 2.64 | 4952 | 482 |
| 3 per-pixel [fusion off] | 1080p | 3 | 4.41 | 0.78 | 0.02 | 0.53 | 2.64 | 3794 | 470 |
| 3 per-pixel [fusion on] | 1080p | 1 | 4.39 | 0.80 | 0.02 | 0.41 | 2.69 | 4898 | 472 |
| 5 per-pixel [fusion off] | 1080p | 5 | 4.59 | 0.91 | 0.03 | 0.50 | 2.75 | 3963 | 451 |
| 5 per-pixel [fusion on] | 1080p | 1 | 4.55 | 0.88 | 0.03 | 0.57 | 2.79 | 3494 | 456 |
| 10 per-pixel [fusion off] | 1080p | 10 | 4.89 | 0.96 | 0.04 | 0.69 | 2.80 | 2817 | 424 |
| 10 per-pixel [fusion on] | 1080p | 1 | 5.08 | 0.94 | 0.05 | 0.65 | 2.92 | 2988 | 409 |
| 3 + blur σ=4 + 3 [fusion off] | 1080p | 8 | 5.66 | 0.89 | 0.04 | 1.25 | 2.93 | 1612 | 366 |
| 3 + blur σ=4 + 3 [fusion on] | 1080p | 4 | 5.57 | 0.90 | 0.04 | 1.38 | 2.86 | 1466 | 372 |
| 2 per-pixel [fusion off] | 4k | 2 | 18.07 | 4.28 | 0.04 | 1.79 | 11.34 | 4526 | 459 |
| 2 per-pixel [fusion on] | 4k | 1 | 19.36 | 4.48 | 0.05 | 1.79 | 12.42 | 4507 | 428 |
| 3 per-pixel [fusion off] | 4k | 3 | 18.61 | 4.33 | 0.04 | 2.10 | 11.51 | 3873 | 446 |
| 3 per-pixel [fusion on] | 4k | 1 | 18.81 | 4.35 | 0.04 | 2.30 | 11.60 | 3549 | 441 |
| 5 per-pixel [fusion off] | 4k | 5 | 19.16 | 4.28 | 0.04 | 2.73 | 11.51 | 2988 | 433 |
| 5 per-pixel [fusion on] | 4k | 1 | 19.23 | 4.25 | 0.05 | 2.97 | 11.60 | 2750 | 431 |
| 10 per-pixel [fusion off] | 4k | 10 | 18.87 | 3.96 | 0.04 | 3.16 | 11.16 | 2591 | 440 |
| 10 per-pixel [fusion on] | 4k | 1 | 18.47 | 4.12 | 0.04 | 2.71 | 11.14 | 3017 | 449 |
| 3 + blur σ=4 + 3 [fusion off] | 4k | 8 | 22.25 | 4.09 | 0.04 | 5.66 | 11.84 | 1455 | 373 |
| 3 + blur σ=4 + 3 [fusion on] | 4k | 4 | 22.55 | 4.20 | 0.05 | 5.78 | 11.95 | 1423 | 368 |
| 2 per-pixel [fusion off] | large | 2 | 49.82 | 11.73 | 0.04 | 4.87 | 32.69 | 4889 | 482 |
| 2 per-pixel [fusion on] | large | 1 | 50.51 | 11.64 | 0.04 | 5.38 | 32.99 | 4424 | 475 |
| 3 per-pixel [fusion off] | large | 3 | 51.80 | 11.48 | 0.04 | 6.89 | 32.97 | 3463 | 463 |
| 3 per-pixel [fusion on] | large | 1 | 51.66 | 11.59 | 0.04 | 6.64 | 33.00 | 3591 | 465 |
| 5 per-pixel [fusion off] | large | 5 | 53.54 | 11.31 | 0.04 | 8.67 | 32.97 | 2755 | 448 |
| 5 per-pixel [fusion on] | large | 1 | 52.87 | 11.24 | 0.04 | 8.26 | 33.05 | 2891 | 454 |
| 10 per-pixel [fusion off] | large | 10 | 54.57 | 11.58 | 0.05 | 9.76 | 32.88 | 2445 | 440 |
| 10 per-pixel [fusion on] | large | 1 | 53.79 | 11.43 | 0.05 | 9.08 | 32.64 | 2630 | 446 |
| 3 + blur σ=4 + 3 [fusion off] | large | 8 | 61.77 | 11.51 | 0.05 | 15.04 | 34.69 | 1590 | 389 |
| 3 + blur σ=4 + 3 [fusion on] | large | 4 | 61.38 | 11.60 | 0.06 | 14.13 | 35.01 | 1692 | 391 |

wrote Benchmarks/results/after-2-fusion.json
