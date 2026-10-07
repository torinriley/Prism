# Prism benchmark

- date: 2026-10-07T02:23:11Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite precision --json Benchmarks/results/after-5-precision.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Precision: 8-bit vs 16-bit float storage

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 per-pixel [texture, 8-bit] | 1080p | 1 | 0.74 | — | 0.03 | 0.51 | — | 3866 | 2808 |
| 10 per-pixel [texture, float16] | 1080p | 1 | 0.56 | — | 0.02 | 0.38 | — | 5214 | 3691 |
| GaussianBlur σ=8 [texture, 8-bit] | 1080p | 2 | 1.04 | — | 0.03 | 0.83 | — | 2416 | 1992 |
| GaussianBlur σ=8 [texture, float16] | 1080p | 2 | 1.04 | — | 0.01 | 0.83 | — | 2444 | 1993 |
| 5-stage [texture, 8-bit] | 1080p | 4 | 0.85 | — | 0.02 | 0.64 | — | 3116 | 2432 |
| 5-stage [texture, float16] | 1080p | 4 | 0.95 | — | 0.04 | 0.72 | — | 2725 | 2183 |
| 10-stage [texture, 8-bit] | 1080p | 8 | 1.60 | — | 0.04 | 1.36 | — | 1479 | 1293 |
| 10-stage [texture, float16] | 1080p | 8 | 2.02 | — | 0.04 | 1.80 | — | 1128 | 1024 |
| 5-stage [CGImage, 8-bit] | 1080p | 4 | 2.13 | 0.48 | 0.05 | 0.73 | 0.38 | 2633 | 972 |
| 5-stage [CGImage, float16] | 1080p | 4 | 4.26 | 1.99 | 0.06 | 0.94 | 0.66 | 2066 | 486 |
| 10 per-pixel [texture, 8-bit] | 4k | 1 | 1.76 | — | 0.03 | 1.55 | — | 5266 | 4700 |
| 10 per-pixel [texture, float16] | 4k | 1 | 1.76 | — | 0.03 | 1.55 | — | 5266 | 4722 |
| GaussianBlur σ=8 [texture, 8-bit] | 4k | 2 | 3.63 | — | 0.02 | 3.45 | — | 2394 | 2284 |
| GaussianBlur σ=8 [texture, float16] | 4k | 2 | 3.67 | — | 0.02 | 3.45 | — | 2386 | 2260 |
| 5-stage [texture, 8-bit] | 4k | 4 | 3.13 | — | 0.03 | 2.91 | — | 2827 | 2648 |
| 5-stage [texture, float16] | 4k | 4 | 3.51 | — | 0.03 | 3.29 | — | 2501 | 2363 |
| 10-stage [texture, 8-bit] | 4k | 8 | 6.23 | — | 0.04 | 5.90 | — | 1397 | 1332 |
| 10-stage [texture, float16] | 4k | 8 | 7.70 | — | 0.04 | 7.51 | — | 1099 | 1078 |
| 5-stage [CGImage, 8-bit] | 4k | 4 | 7.25 | 1.91 | 0.06 | 3.15 | 1.66 | 2577 | 1144 |
| 5-stage [CGImage, float16] | 4k | 4 | 14.19 | 7.63 | 0.06 | 3.66 | 2.51 | 2226 | 585 |
| 10 per-pixel [texture, 8-bit] | large | 1 | 4.69 | — | 0.03 | 4.52 | — | 5278 | 5114 |
| 10 per-pixel [texture, float16] | large | 1 | 4.61 | — | 0.03 | 4.36 | — | 5459 | 5207 |
| GaussianBlur σ=8 [texture, 8-bit] | large | 2 | 9.74 | — | 0.02 | 9.54 | — | 2511 | 2463 |
| GaussianBlur σ=8 [texture, float16] | large | 2 | 14.85 | — | 0.12 | 9.56 | — | 2479 | 1617 |
| 5-stage [texture, 8-bit] | large | 4 | 7.72 | — | 0.03 | 7.50 | — | 3189 | 3108 |
| 5-stage [texture, float16] | large | 4 | 13.65 | — | 0.12 | 8.57 | — | 2761 | 1758 |
| 10-stage [texture, 8-bit] | large | 8 | 24.96 | — | 0.17 | 21.26 | — | 1120 | 961 |
| 10-stage [texture, float16] | large | 8 | 41.47 | — | 0.27 | 28.17 | — | 844 | 579 |
| 5-stage [CGImage, 8-bit] | large | 4 | 31.94 | 7.22 | 0.26 | 11.15 | 7.28 | 2103 | 751 |
| 5-stage [CGImage, float16] | large | 4 | 81.15 | 39.23 | 0.28 | 13.53 | 13.32 | 1738 | 296 |

wrote Benchmarks/results/after-5-precision.json
