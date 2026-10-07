# Prism benchmark

- date: 2026-10-07T02:11:12Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite blur,texture,ops --json Benchmarks/results/after-4-blur-lut.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Single operations (warm renderer, 30 iterations, 5 warm-up)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Exposure | 1080p | 1 | 1.18 | 0.34 | 0.03 | 0.24 | 0.38 | 7937 | 1756 |
| Contrast | 1080p | 1 | 1.08 | 0.34 | 0.02 | 0.22 | 0.34 | 8536 | 1913 |
| Saturation | 1080p | 1 | 1.08 | 0.33 | 0.02 | 0.22 | 0.35 | 8622 | 1924 |
| Temperature | 1080p | 1 | 1.09 | 0.33 | 0.02 | 0.22 | 0.34 | 8637 | 1907 |
| GaussianBlur σ=2 | 1080p | 2 | 1.28 | 0.34 | 0.02 | 0.38 | 0.35 | 5104 | 1621 |
| GaussianBlur σ=8 | 1080p | 2 | 1.85 | 0.35 | 0.03 | 0.89 | 0.37 | 2257 | 1121 |
| GaussianBlur σ=32 | 1080p | 2 | 4.94 | 0.41 | 0.03 | 3.92 | 0.37 | 525 | 419 |
| Sharpen | 1080p | 3 | 1.51 | 0.35 | 0.03 | 0.52 | 0.38 | 3774 | 1376 |
| Resize 0.5× | 1080p | 1 | 0.66 | 0.23 | 0.02 | 0.18 | 0.08 | 10368 | 3137 |
| Vignette | 1080p | 1 | 1.08 | 0.32 | 0.02 | 0.22 | 0.34 | 8645 | 1928 |
| LUT 33³ | 1080p | 1 | 1.29 | 0.34 | 0.02 | 0.40 | 0.35 | 4919 | 1607 |
| Exposure | 4k | 1 | 4.78 | 1.76 | 0.03 | 0.93 | 1.58 | 8724 | 1737 |
| Contrast | 4k | 1 | 4.79 | 1.78 | 0.03 | 0.93 | 1.58 | 8692 | 1730 |
| Saturation | 4k | 1 | 4.81 | 1.80 | 0.03 | 0.92 | 1.60 | 8732 | 1725 |
| Temperature | 4k | 1 | 4.81 | 1.78 | 0.03 | 0.94 | 1.58 | 8580 | 1724 |
| GaussianBlur σ=2 | 4k | 2 | 5.49 | 1.77 | 0.03 | 1.67 | 1.57 | 4876 | 1511 |
| GaussianBlur σ=8 | 4k | 2 | 7.47 | 1.82 | 0.03 | 3.57 | 1.57 | 2302 | 1111 |
| GaussianBlur σ=32 | 4k | 2 | 19.62 | 1.84 | 0.04 | 15.75 | 1.56 | 525 | 423 |
| Sharpen | 4k | 3 | 5.85 | 1.82 | 0.04 | 1.98 | 1.60 | 4105 | 1417 |
| Resize 0.5× | 4k | 1 | 3.12 | 1.79 | 0.03 | 0.51 | 0.37 | 15414 | 2655 |
| Vignette | 4k | 1 | 4.72 | 1.82 | 0.03 | 0.83 | 1.59 | 9633 | 1757 |
| LUT 33³ | 4k | 1 | 5.49 | 1.83 | 0.03 | 1.63 | 1.59 | 5002 | 1511 |
| Exposure | large | 1 | 12.43 | 4.82 | 0.04 | 2.47 | 4.71 | 9555 | 1931 |
| Contrast | large | 1 | 12.49 | 4.79 | 0.04 | 2.51 | 4.66 | 9393 | 1922 |
| Saturation | large | 1 | 12.42 | 4.75 | 0.04 | 2.51 | 4.67 | 9415 | 1932 |
| Temperature | large | 1 | 12.53 | 4.81 | 0.04 | 2.59 | 4.68 | 9132 | 1915 |
| GaussianBlur σ=2 | large | 2 | 14.47 | 4.81 | 0.04 | 4.53 | 4.71 | 5253 | 1658 |
| GaussianBlur σ=8 | large | 2 | 20.33 | 4.82 | 0.05 | 10.38 | 4.72 | 2303 | 1181 |
| GaussianBlur σ=32 | large | 2 | 55.66 | 4.71 | 0.05 | 45.67 | 4.71 | 525 | 431 |
| Sharpen | large | 3 | 15.54 | 4.85 | 0.05 | 5.51 | 4.75 | 4319 | 1544 |
| Resize 0.5× | large | 1 | 7.94 | 4.84 | 0.04 | 1.48 | 1.09 | 15832 | 3022 |
| Vignette | large | 1 | 12.60 | 4.88 | 0.04 | 2.54 | 4.72 | 9299 | 1904 |
| LUT 33³ | large | 1 | 14.81 | 4.82 | 0.04 | 4.75 | 4.70 | 5007 | 1620 |

## Gaussian blur, texture in/out

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GaussianBlur σ=1 [texture] | 1080p | 2 | 0.74 | — | 0.03 | 0.26 | — | 7232 | 2813 |
| GaussianBlur σ=2 [texture] | 1080p | 2 | 0.49 | — | 0.01 | 0.30 | — | 6851 | 4235 |
| GaussianBlur σ=4 [texture] | 1080p | 2 | 0.70 | — | 0.03 | 0.47 | — | 4201 | 2983 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.03 | — | 0.03 | 0.83 | — | 2421 | 2020 |
| GaussianBlur σ=16 [texture] | 1080p | 2 | 1.81 | — | 0.03 | 1.59 | — | 1279 | 1144 |
| GaussianBlur σ=32 [texture] | 1080p | 2 | 4.06 | — | 0.03 | 3.85 | — | 535 | 510 |
| GaussianBlur σ=64 [texture] | 1080p | 2 | 10.43 | — | 0.03 | 10.19 | — | 203 | 199 |
| GaussianBlur σ=1 [texture] | 4k | 2 | 1.20 | — | 0.03 | 0.99 | — | 8140 | 6899 |
| GaussianBlur σ=2 [texture] | 4k | 2 | 1.42 | — | 0.03 | 1.21 | — | 6678 | 5829 |
| GaussianBlur σ=4 [texture] | 4k | 2 | 2.06 | — | 0.03 | 1.86 | — | 4373 | 4034 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 3.53 | — | 0.03 | 3.30 | — | 2492 | 2351 |
| GaussianBlur σ=16 [texture] | 4k | 2 | 6.60 | — | 0.03 | 6.38 | — | 1295 | 1256 |
| GaussianBlur σ=32 [texture] | 4k | 2 | 15.70 | — | 0.03 | 15.47 | — | 535 | 528 |
| GaussianBlur σ=64 [texture] | 4k | 2 | 41.15 | — | 0.03 | 40.88 | — | 203 | 202 |
| GaussianBlur σ=1 [texture] | large | 2 | 3.10 | — | 0.03 | 2.89 | — | 8221 | 7739 |
| GaussianBlur σ=2 [texture] | large | 2 | 3.80 | — | 0.03 | 3.58 | — | 6654 | 6319 |
| GaussianBlur σ=4 [texture] | large | 2 | 5.61 | — | 0.03 | 5.39 | — | 4433 | 4275 |
| GaussianBlur σ=8 [texture] | large | 2 | 9.78 | — | 0.03 | 9.55 | — | 2507 | 2453 |
| GaussianBlur σ=16 [texture] | large | 2 | 18.70 | — | 0.03 | 18.47 | — | 1297 | 1283 |
| GaussianBlur σ=32 [texture] | large | 2 | 45.11 | — | 0.03 | 44.85 | — | 535 | 532 |
| GaussianBlur σ=64 [texture] | large | 2 | 118.94 | — | 0.02 | 118.69 | — | 202 | 202 |

## Texture in / texture out (warm renderer, destination reused)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Exposure [texture] | 1080p | 1 | 0.28 | — | 0.01 | 0.10 | — | 19636 | 7316 |
| Contrast [texture] | 1080p | 1 | 0.28 | — | 0.01 | 0.10 | — | 20091 | 7345 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.04 | — | 0.03 | 0.83 | — | 2419 | 2003 |
| Sharpen [texture] | 1080p | 3 | 0.56 | — | 0.01 | 0.37 | — | 5508 | 3711 |
| LUT 33³ [texture] | 1080p | 1 | 0.53 | — | 0.01 | 0.34 | — | 6072 | 3935 |
| 5-stage [texture] | 1080p | 4 | 0.88 | — | 0.04 | 0.65 | — | 2980 | 2358 |
| 10-stage [texture] | 1080p | 8 | 1.61 | — | 0.05 | 1.36 | — | 1475 | 1286 |
| 10 per-pixel [texture] | 1080p | 1 | 0.59 | — | 0.02 | 0.38 | — | 5236 | 3542 |
| Exposure [texture] | 4k | 1 | 0.53 | — | 0.01 | 0.34 | — | 24035 | 15687 |
| Contrast [texture] | 4k | 1 | 0.51 | — | 0.01 | 0.32 | — | 25052 | 16369 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 3.51 | — | 0.03 | 3.30 | — | 2496 | 2363 |
| Sharpen [texture] | 4k | 3 | 1.70 | — | 0.03 | 1.49 | — | 5445 | 4881 |
| LUT 33³ [texture] | 4k | 1 | 1.52 | — | 0.02 | 1.32 | — | 6194 | 5473 |
| 5-stage [texture] | 4k | 4 | 2.82 | — | 0.04 | 2.59 | — | 3155 | 2943 |
| 10-stage [texture] | 4k | 8 | 5.78 | — | 0.05 | 5.52 | — | 1490 | 1434 |
| 10 per-pixel [texture] | 4k | 1 | 1.74 | — | 0.04 | 1.51 | — | 5342 | 4771 |
| Exposure [texture] | large | 1 | 1.18 | — | 0.02 | 0.96 | — | 24448 | 20385 |
| Contrast [texture] | large | 1 | 1.15 | — | 0.02 | 0.94 | — | 25048 | 20787 |
| GaussianBlur σ=8 [texture] | large | 2 | 9.77 | — | 0.03 | 9.53 | — | 2510 | 2457 |
| Sharpen [texture] | large | 3 | 4.62 | — | 0.03 | 4.39 | — | 5429 | 5200 |
| LUT 33³ [texture] | large | 1 | 4.01 | — | 0.02 | 3.80 | — | 6285 | 5978 |
| 5-stage [texture] | large | 4 | 7.72 | — | 0.04 | 7.48 | — | 3188 | 3111 |
| 10-stage [texture] | large | 8 | 16.35 | — | 0.04 | 16.05 | — | 1492 | 1468 |
| 10 per-pixel [texture] | large | 1 | 4.60 | — | 0.04 | 4.37 | — | 5443 | 5216 |

wrote Benchmarks/results/after-4-blur-lut.json
