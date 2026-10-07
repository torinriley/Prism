# Prism benchmark

- date: 2026-10-07T01:41:32Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite ops,pipelines,texture --json Benchmarks/results/after-3-conversions.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Single operations (warm renderer, 30 iterations, 5 warm-up)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Exposure | 1080p | 1 | 1.54 | 0.43 | 0.03 | 0.40 | 0.35 | 4843 | 1349 |
| Contrast | 1080p | 1 | 1.34 | 0.42 | 0.03 | 0.35 | 0.35 | 5475 | 1543 |
| Saturation | 1080p | 1 | 1.41 | 0.42 | 0.03 | 0.35 | 0.36 | 5461 | 1473 |
| Temperature | 1080p | 1 | 1.36 | 0.39 | 0.02 | 0.40 | 0.36 | 4909 | 1526 |
| GaussianBlur σ=2 | 1080p | 2 | 3.53 | 0.47 | 0.03 | 2.48 | 0.36 | 827 | 587 |
| GaussianBlur σ=8 | 1080p | 2 | 2.80 | 0.45 | 0.03 | 1.78 | 0.36 | 1148 | 740 |
| GaussianBlur σ=32 | 1080p | 2 | 7.91 | 0.53 | 0.04 | 6.71 | 0.39 | 307 | 262 |
| Sharpen | 1080p | 3 | 1.76 | 0.44 | 0.03 | 0.67 | 0.41 | 2942 | 1177 |
| Resize 0.5× | 1080p | 1 | 0.66 | 0.23 | 0.02 | 0.18 | 0.08 | 10619 | 3151 |
| Vignette | 1080p | 1 | 1.11 | 0.36 | 0.02 | 0.21 | 0.34 | 8900 | 1868 |
| LUT 33³ | 1080p | 1 | 1.82 | 0.41 | 0.47 | 0.39 | 0.35 | 2406 | 1137 |
| Exposure | 4k | 1 | 4.61 | 1.83 | 0.03 | 0.74 | 1.60 | 10698 | 1800 |
| Contrast | 4k | 1 | 4.79 | 1.83 | 0.03 | 0.92 | 1.60 | 8725 | 1732 |
| Saturation | 4k | 1 | 4.79 | 1.82 | 0.03 | 0.91 | 1.60 | 8792 | 1733 |
| Temperature | 4k | 1 | 4.76 | 1.83 | 0.03 | 0.89 | 1.61 | 9040 | 1744 |
| GaussianBlur σ=2 | 4k | 2 | 6.26 | 1.84 | 0.04 | 2.40 | 1.58 | 3397 | 1325 |
| GaussianBlur σ=8 | 4k | 2 | 11.16 | 1.85 | 0.04 | 7.29 | 1.59 | 1132 | 743 |
| GaussianBlur σ=32 | 4k | 2 | 33.33 | 1.97 | 0.05 | 29.47 | 1.60 | 281 | 249 |
| Sharpen | 4k | 3 | 7.06 | 1.97 | 0.05 | 2.76 | 1.67 | 2956 | 1175 |
| Resize 0.5× | 4k | 1 | 3.36 | 2.07 | 0.04 | 0.46 | 0.37 | 16554 | 2466 |
| Vignette | 4k | 1 | 4.94 | 1.97 | 0.04 | 0.79 | 1.73 | 9933 | 1680 |
| LUT 33³ | 4k | 1 | 6.44 | 1.97 | 0.52 | 1.66 | 1.68 | 3804 | 1287 |
| Exposure | large | 1 | 13.18 | 5.05 | 0.05 | 2.73 | 4.88 | 8628 | 1821 |
| Contrast | large | 1 | 12.74 | 4.91 | 0.05 | 2.63 | 4.78 | 8988 | 1883 |
| Saturation | large | 1 | 12.92 | 4.90 | 0.04 | 2.71 | 4.75 | 8728 | 1858 |
| Temperature | large | 1 | 12.74 | 4.90 | 0.05 | 2.64 | 4.74 | 8946 | 1884 |
| GaussianBlur σ=2 | large | 2 | 16.91 | 4.86 | 0.05 | 6.96 | 4.72 | 3427 | 1419 |
| GaussianBlur σ=8 | large | 2 | 31.22 | 4.90 | 0.05 | 21.14 | 4.70 | 1132 | 769 |
| GaussianBlur σ=32 | large | 2 | 87.06 | 4.90 | 0.06 | 76.90 | 4.82 | 312 | 276 |
| Sharpen | large | 3 | 17.62 | 4.93 | 0.05 | 7.52 | 4.78 | 3170 | 1362 |
| Resize 0.5× | large | 1 | 7.88 | 4.90 | 0.04 | 1.38 | 1.12 | 16864 | 3047 |
| Vignette | large | 1 | 12.85 | 4.94 | 0.05 | 2.67 | 4.75 | 8839 | 1868 |
| LUT 33³ | large | 1 | 15.38 | 4.91 | 0.54 | 4.77 | 4.74 | 4527 | 1560 |

## Multi-stage pipelines (warm renderer)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 4 | 4.32 | 0.49 | 0.05 | 3.27 | 0.36 | 625 | 480 |
| 10-stage | 1080p | 8 | 5.39 | 0.51 | 0.55 | 3.45 | 0.36 | 518 | 385 |
| 10 per-pixel | 1080p | 1 | 1.62 | 0.41 | 0.04 | 0.63 | 0.36 | 3118 | 1280 |
| 5-stage | 4k | 4 | 9.97 | 1.94 | 0.05 | 5.89 | 1.64 | 1395 | 832 |
| 10-stage | 4k | 8 | 12.48 | 1.84 | 0.53 | 7.99 | 1.63 | 974 | 665 |
| 10 per-pixel | 4k | 1 | 5.66 | 1.87 | 0.05 | 1.81 | 1.60 | 4465 | 1466 |
| 5-stage | large | 4 | 25.20 | 5.34 | 0.08 | 13.70 | 5.63 | 1741 | 953 |
| 10-stage | large | 8 | 39.66 | 6.97 | 0.63 | 23.18 | 4.78 | 1008 | 605 |
| 10 per-pixel | large | 1 | 15.56 | 4.92 | 0.06 | 5.33 | 4.77 | 4454 | 1542 |

## Texture in / texture out (warm renderer, destination reused)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Exposure [texture] | 1080p | 1 | 0.28 | — | 0.01 | 0.10 | — | 20342 | 7442 |
| Contrast [texture] | 1080p | 1 | 0.28 | — | 0.01 | 0.09 | — | 20976 | 7516 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.92 | — | 0.03 | 1.71 | — | 1192 | 1081 |
| Sharpen [texture] | 1080p | 3 | 0.72 | — | 0.03 | 0.50 | — | 3920 | 2876 |
| LUT 33³ [texture] | 1080p | 1 | 0.93 | — | 0.41 | 0.33 | — | 2799 | 2232 |
| 5-stage [texture] | 1080p | 4 | 1.29 | — | 0.05 | 1.06 | — | 1871 | 1604 |
| 10-stage [texture] | 1080p | 8 | 2.54 | — | 0.44 | 1.87 | — | 897 | 816 |
| 10 per-pixel [texture] | 1080p | 1 | 0.56 | — | 0.02 | 0.38 | — | 5166 | 3694 |
| Exposure [texture] | 4k | 1 | 0.51 | — | 0.01 | 0.33 | — | 24503 | 16164 |
| Contrast [texture] | 4k | 1 | 0.54 | — | 0.01 | 0.35 | — | 23106 | 15459 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 7.20 | — | 0.03 | 6.98 | — | 1184 | 1152 |
| Sharpen [texture] | 4k | 3 | 2.46 | — | 0.03 | 2.25 | — | 3639 | 3370 |
| LUT 33³ [texture] | 4k | 1 | 1.98 | — | 0.45 | 1.31 | — | 4709 | 4198 |
| 5-stage [texture] | 4k | 4 | 4.62 | — | 0.04 | 4.40 | — | 1867 | 1796 |
| 10-stage [texture] | 4k | 8 | 8.36 | — | 0.46 | 7.66 | — | 1021 | 992 |
| 10 per-pixel [texture] | 4k | 1 | 1.75 | — | 0.05 | 1.51 | — | 5338 | 4749 |
| Exposure [texture] | large | 1 | 1.16 | — | 0.02 | 0.96 | — | 24537 | 20628 |
| Contrast [texture] | large | 1 | 1.15 | — | 0.02 | 0.94 | — | 25096 | 20923 |
| GaussianBlur σ=8 [texture] | large | 2 | 20.69 | — | 0.03 | 20.46 | — | 1171 | 1160 |
| Sharpen [texture] | large | 3 | 6.73 | — | 0.03 | 6.52 | — | 3661 | 3568 |
| LUT 33³ [texture] | large | 1 | 4.48 | — | 0.45 | 3.80 | — | 5640 | 5362 |
| 5-stage [texture] | large | 4 | 13.10 | — | 0.04 | 12.88 | — | 1858 | 1832 |
| 10-stage [texture] | large | 8 | 23.12 | — | 0.47 | 22.41 | — | 1049 | 1038 |
| 10 per-pixel [texture] | large | 1 | 4.60 | — | 0.04 | 4.36 | — | 5449 | 5217 |

wrote Benchmarks/results/after-3-conversions.json
