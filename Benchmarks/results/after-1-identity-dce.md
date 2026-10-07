# Prism benchmark

- date: 2026-10-07T00:17:45Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite optimizer,pipelines --json Benchmarks/results/after-1-identity-dce.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Multi-stage pipelines (warm renderer)

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 5-stage | 1080p | 6 | 6.22 | 0.85 | 0.03 | 1.85 | 3.03 | 1104 | 333 |
| 10-stage | 1080p | 13 | 6.66 | 0.87 | 0.48 | 2.11 | 2.75 | 802 | 312 |
| 10 per-pixel | 1080p | 10 | 4.67 | 0.81 | 0.03 | 0.73 | 2.61 | 2748 | 444 |
| 5-stage | 4k | 6 | 21.32 | 4.10 | 0.04 | 4.96 | 11.59 | 1662 | 389 |
| 10-stage | 4k | 13 | 24.92 | 4.13 | 0.50 | 8.24 | 11.44 | 948 | 333 |
| 10 per-pixel | 4k | 10 | 19.08 | 4.16 | 0.04 | 3.26 | 11.03 | 2514 | 435 |
| 5-stage | large | 6 | 61.56 | 11.68 | 0.05 | 13.85 | 34.65 | 1728 | 390 |
| 10-stage | large | 13 | 76.34 | 13.84 | 0.57 | 24.49 | 34.38 | 958 | 314 |
| 10 per-pixel | large | 10 | 52.75 | 11.77 | 0.05 | 7.86 | 32.66 | 3034 | 455 |

## Graph optimizer: off vs on

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 6 neutral stages [opt off] | 1080p | 9 | 4.86 | 0.85 | 0.02 | 0.93 | 2.61 | 2171 | 427 |
| 6 neutral stages [opt on] | 1080p | 0 | 1.33 | 0.78 | 0.01 | 0.00 | 0.52 | 195934 | 1561 |
| 1 active + 5 neutral [opt off] | 1080p | 9 | 4.80 | 0.82 | 0.02 | 0.88 | 2.61 | 2292 | 432 |
| 1 active + 5 neutral [opt on] | 1080p | 1 | 4.41 | 0.83 | 0.02 | 0.37 | 2.70 | 5310 | 470 |
| blur + 5 neutral [opt off] | 1080p | 9 | 6.56 | 0.84 | 0.02 | 2.44 | 2.78 | 842 | 316 |
| blur + 5 neutral [opt on] | 1080p | 2 | 5.83 | 0.84 | 0.02 | 1.72 | 2.82 | 1192 | 356 |
| 6 neutral stages [opt off] | 4k | 9 | 19.24 | 4.11 | 0.03 | 3.31 | 11.18 | 2481 | 431 |
| 6 neutral stages [opt on] | 4k | 0 | 6.73 | 4.19 | 0.02 | 0.00 | 2.44 | 472849 | 1232 |
| 1 active + 5 neutral [opt off] | 4k | 9 | 19.39 | 4.17 | 0.04 | 3.50 | 11.24 | 2344 | 428 |
| 1 active + 5 neutral [opt on] | 4k | 1 | 17.26 | 4.12 | 0.03 | 1.31 | 11.31 | 6192 | 480 |
| blur + 5 neutral [opt off] | 4k | 9 | 25.95 | 4.18 | 0.04 | 9.37 | 11.79 | 882 | 320 |
| blur + 5 neutral [opt on] | 4k | 2 | 23.87 | 4.26 | 0.04 | 7.04 | 12.02 | 1173 | 347 |
| 6 neutral stages [opt off] | large | 9 | 53.21 | 11.39 | 0.04 | 8.85 | 32.48 | 2699 | 451 |
| 6 neutral stages [opt on] | large | 0 | 18.92 | 11.36 | 0.02 | 0.00 | 7.33 | 1044432 | 1269 |
| 1 active + 5 neutral [opt off] | large | 9 | 53.71 | 11.37 | 0.04 | 8.93 | 32.68 | 2676 | 447 |
| 1 active + 5 neutral [opt on] | large | 1 | 47.74 | 11.51 | 0.04 | 3.03 | 32.68 | 7822 | 503 |
| blur + 5 neutral [opt off] | large | 9 | 73.04 | 11.57 | 0.04 | 26.91 | 33.86 | 891 | 329 |
| blur + 5 neutral [opt on] | large | 2 | 66.76 | 11.73 | 0.04 | 20.27 | 33.84 | 1182 | 359 |

wrote Benchmarks/results/after-1-identity-dce.json
