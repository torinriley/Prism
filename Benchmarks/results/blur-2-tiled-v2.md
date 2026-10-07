# Prism benchmark

- date: 2026-10-07T01:46:58Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite blur --json Benchmarks/results/blur-2-tiled-v2.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Gaussian blur, texture in/out

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GaussianBlur σ=1 [texture] | 1080p | 2 | 1.37 | — | 0.03 | 1.00 | — | 2021 | 1513 |
| GaussianBlur σ=2 [texture] | 1080p | 2 | 1.36 | — | 0.03 | 0.99 | — | 2041 | 1526 |
| GaussianBlur σ=4 [texture] | 1080p | 2 | 1.26 | — | 0.02 | 0.97 | — | 2090 | 1647 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.22 | — | 0.03 | 1.03 | — | 1967 | 1703 |
| GaussianBlur σ=16 [texture] | 1080p | 2 | 2.24 | — | 0.03 | 2.04 | — | 1003 | 924 |
| GaussianBlur σ=32 [texture] | 1080p | 2 | 6.76 | — | 0.03 | 6.55 | — | 315 | 307 |
| GaussianBlur σ=64 [texture] | 1080p | 2 | 13.24 | — | 0.03 | 13.02 | — | 159 | 157 |
| GaussianBlur σ=1 [texture] | 4k | 2 | 1.25 | — | 0.03 | 1.05 | — | 7691 | 6619 |
| GaussianBlur σ=2 [texture] | 4k | 2 | 1.44 | — | 0.03 | 1.24 | — | 6570 | 5743 |
| GaussianBlur σ=4 [texture] | 4k | 2 | 2.13 | — | 0.03 | 1.92 | — | 4264 | 3890 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 3.89 | — | 0.03 | 3.67 | — | 2245 | 2134 |
| GaussianBlur σ=16 [texture] | 4k | 2 | 8.45 | — | 0.03 | 8.24 | — | 1003 | 982 |
| GaussianBlur σ=32 [texture] | 4k | 2 | 26.85 | — | 0.02 | 26.62 | — | 311 | 309 |
| GaussianBlur σ=64 [texture] | 4k | 2 | 52.45 | — | 0.03 | 52.23 | — | 159 | 158 |
| GaussianBlur σ=1 [texture] | large | 2 | 3.29 | — | 0.03 | 3.08 | — | 7715 | 7300 |
| GaussianBlur σ=2 [texture] | large | 2 | 3.86 | — | 0.03 | 3.64 | — | 6545 | 6222 |
| GaussianBlur σ=4 [texture] | large | 2 | 5.81 | — | 0.03 | 5.58 | — | 4280 | 4134 |
| GaussianBlur σ=8 [texture] | large | 2 | 11.00 | — | 0.03 | 10.71 | — | 2235 | 2182 |
| GaussianBlur σ=16 [texture] | large | 2 | 24.04 | — | 0.03 | 23.80 | — | 1007 | 998 |
| GaussianBlur σ=32 [texture] | large | 2 | 77.03 | — | 0.02 | 76.78 | — | 312 | 312 |
| GaussianBlur σ=64 [texture] | large | 2 | 153.02 | — | 0.03 | 152.76 | — | 157 | 157 |

wrote Benchmarks/results/blur-2-tiled-v2.json
