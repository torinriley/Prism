# Prism benchmark

- date: 2026-10-07T01:44:04Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite blur --json Benchmarks/results/blur-0-before.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Gaussian blur, texture in/out

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GaussianBlur σ=1 [texture] | 1080p | 2 | 1.59 | — | 0.01 | 1.31 | — | 1573 | 1307 |
| GaussianBlur σ=2 [texture] | 1080p | 2 | 1.27 | — | 0.01 | 1.05 | — | 1955 | 1629 |
| GaussianBlur σ=4 [texture] | 1080p | 2 | 1.36 | — | 0.01 | 1.18 | — | 1747 | 1529 |
| GaussianBlur σ=8 [texture] | 1080p | 2 | 1.89 | — | 0.02 | 1.69 | — | 1215 | 1095 |
| GaussianBlur σ=16 [texture] | 1080p | 2 | 3.46 | — | 0.02 | 3.27 | — | 630 | 599 |
| GaussianBlur σ=32 [texture] | 1080p | 2 | 6.64 | — | 0.03 | 6.44 | — | 321 | 312 |
| GaussianBlur σ=64 [texture] | 1080p | 2 | 13.05 | — | 0.03 | 12.83 | — | 161 | 159 |
| GaussianBlur σ=1 [texture] | 4k | 2 | 1.50 | — | 0.03 | 1.30 | — | 6241 | 5517 |
| GaussianBlur σ=2 [texture] | 4k | 2 | 2.29 | — | 0.03 | 2.07 | — | 3953 | 3623 |
| GaussianBlur σ=4 [texture] | 4k | 2 | 4.27 | — | 0.03 | 4.06 | — | 2031 | 1944 |
| GaussianBlur σ=8 [texture] | 4k | 2 | 7.90 | — | 0.02 | 7.70 | — | 1075 | 1051 |
| GaussianBlur σ=16 [texture] | 4k | 2 | 13.94 | — | 0.02 | 13.72 | — | 603 | 595 |
| GaussianBlur σ=32 [texture] | 4k | 2 | 26.60 | — | 0.03 | 26.38 | — | 314 | 312 |
| GaussianBlur σ=64 [texture] | 4k | 2 | 52.59 | — | 0.03 | 52.38 | — | 158 | 158 |
| GaussianBlur σ=1 [texture] | large | 2 | 3.98 | — | 0.03 | 3.77 | — | 6321 | 6026 |
| GaussianBlur σ=2 [texture] | large | 2 | 6.21 | — | 0.03 | 5.99 | — | 3990 | 3862 |
| GaussianBlur σ=4 [texture] | large | 2 | 10.99 | — | 0.03 | 10.78 | — | 2221 | 2183 |
| GaussianBlur σ=8 [texture] | large | 2 | 20.39 | — | 0.03 | 20.18 | — | 1188 | 1177 |
| GaussianBlur σ=16 [texture] | large | 2 | 38.98 | — | 0.03 | 38.76 | — | 619 | 616 |
| GaussianBlur σ=32 [texture] | large | 2 | 76.98 | — | 0.03 | 76.75 | — | 313 | 312 |
| GaussianBlur σ=64 [texture] | large | 2 | 152.51 | — | 0.03 | 152.24 | — | 158 | 157 |

wrote Benchmarks/results/blur-0-before.json
