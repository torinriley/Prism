# Prism benchmark

- date: 2026-10-07T01:45:19Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite blur --json Benchmarks/results/blur-1-tiled-v1.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Gaussian blur, texture in/out

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GaussianBlur σ=1 [texture] | 1080p | 2 | 1.29 | — | 0.03 | 0.95 | — | 2132 | 1602 |
| GaussianBlur σ=2 [texture] | 1080p | 2 | 1.44 | — | 0.03 | 1.14 | — | 1776 | 1436 |
| GaussianBlur σ=4 [texture] | 1080p | 2 | 1.55 | — | 0.03 | 1.27 | — | 1605 | 1339 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.63 | — | 0.03 | 1.42 | — | 1433 | 1271 |
| GaussianBlur σ=16 [texture] | 1080p | 2 | 2.95 | — | 0.03 | 2.74 | — | 750 | 703 |
| GaussianBlur σ=32 [texture] | 1080p | 2 | 6.81 | — | 0.03 | 6.60 | — | 313 | 305 |
| GaussianBlur σ=64 [texture] | 1080p | 2 | 13.82 | — | 0.03 | 13.58 | — | 152 | 150 |
| GaussianBlur σ=1 [texture] | 4k | 2 | 1.37 | — | 0.01 | 1.18 | — | 6962 | 6048 |
| GaussianBlur σ=2 [texture] | 4k | 2 | 1.99 | — | 0.02 | 1.79 | — | 4595 | 4165 |
| GaussianBlur σ=4 [texture] | 4k | 2 | 3.27 | — | 0.01 | 3.07 | — | 2690 | 2536 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 5.89 | — | 0.02 | 5.71 | — | 1447 | 1407 |
| GaussianBlur σ=16 [texture] | 4k | 2 | 11.20 | — | 0.02 | 10.96 | — | 755 | 741 |
| GaussianBlur σ=32 [texture] | 4k | 2 | 26.81 | — | 0.03 | 26.55 | — | 312 | 309 |
| GaussianBlur σ=64 [texture] | 4k | 2 | 52.38 | — | 0.03 | 52.14 | — | 159 | 158 |
| GaussianBlur σ=1 [texture] | large | 2 | 3.55 | — | 0.03 | 3.34 | — | 7123 | 6760 |
| GaussianBlur σ=2 [texture] | large | 2 | 5.33 | — | 0.03 | 5.10 | — | 4675 | 4501 |
| GaussianBlur σ=4 [texture] | large | 2 | 9.05 | — | 0.03 | 8.83 | — | 2708 | 2652 |
| GaussianBlur σ=8 [texture] | large | 2 | 18.07 | — | 0.03 | 17.67 | — | 1356 | 1329 |
| GaussianBlur σ=16 [texture] | large | 2 | 32.06 | — | 0.03 | 31.84 | — | 753 | 749 |
| GaussianBlur σ=32 [texture] | large | 2 | 77.47 | — | 0.03 | 77.18 | — | 311 | 310 |
| GaussianBlur σ=64 [texture] | large | 2 | 153.32 | — | 0.03 | 153.05 | — | 157 | 157 |

wrote Benchmarks/results/blur-1-tiled-v1.json
