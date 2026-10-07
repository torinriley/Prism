# Prism benchmark

- date: 2026-10-07T01:19:03Z
- machine: Mac17,2, Apple M5, 16 GiB, GPU Apple M5 (unified memory: true)
- OS: Version 27.0.1 (Build 26A434)
- build: release; thermal state: nominal; low power mode: false
- arguments: --suite alu --resolutions 4k --json Benchmarks/results/diagnosis-alu-vs-bandwidth.json
- method: median of 30 renders after 5 warm-up renders on one warmed `Renderer`; columns are medians. `total` is the whole `render` call; `import`/`export` are CGImage↔texture conversion; `encode` is CPU command-buffer construction; `gpu` is Metal's command-buffer execution time. `engine MP/s` uses encode+gpu only; `e2e MP/s` uses `total`.
- input: synthetic image (deterministic gradients, edges, noise, alpha ramp); not a photograph

## Memory vs arithmetic: N identical per-pixel operations

| case | res | passes | total ms | import | encode | gpu | export | engine MP/s | e2e MP/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1× Contrast [fusion off] | 4k | 1 | 17.29 | 4.42 | 0.03 | 1.06 | 11.30 | 7631 | 480 |
| 2× Contrast [fusion off] | 4k | 2 | 18.31 | 4.53 | 0.03 | 1.66 | 11.39 | 4909 | 453 |
| 2× Contrast [fusion on] | 4k | 1 | 18.20 | 4.57 | 0.05 | 1.42 | 11.63 | 5636 | 456 |
| 5× Contrast [fusion off] | 4k | 5 | 19.71 | 4.55 | 0.05 | 2.77 | 11.80 | 2938 | 421 |
| 5× Contrast [fusion on] | 4k | 1 | 18.93 | 4.46 | 0.05 | 2.20 | 11.68 | 3691 | 438 |
| 10× Contrast [fusion off] | 4k | 10 | 19.58 | 4.48 | 0.05 | 2.91 | 11.57 | 2802 | 424 |
| 10× Contrast [fusion on] | 4k | 1 | 18.32 | 4.20 | 0.04 | 2.27 | 11.27 | 3587 | 453 |
| 20× Contrast [fusion off] | 4k | 20 | 20.80 | 4.24 | 0.05 | 4.73 | 11.27 | 1736 | 399 |
| 20× Contrast [fusion on] | 4k | 1 | 18.78 | 4.07 | 0.05 | 2.91 | 11.26 | 2804 | 442 |
| 40× Contrast [fusion off] | 4k | 40 | 24.71 | 4.13 | 0.07 | 8.66 | 11.32 | 950 | 336 |
| 40× Contrast [fusion on] | 4k | 2 | 20.28 | 4.17 | 0.07 | 4.28 | 11.23 | 1907 | 409 |
| 1× Saturation [fusion off] | 4k | 1 | 17.29 | 4.27 | 0.02 | 1.13 | 11.39 | 7183 | 480 |
| 2× Saturation [fusion off] | 4k | 2 | 17.74 | 4.16 | 0.03 | 1.78 | 11.25 | 4599 | 468 |
| 2× Saturation [fusion on] | 4k | 1 | 18.04 | 4.45 | 0.04 | 1.43 | 11.60 | 5666 | 460 |
| 5× Saturation [fusion off] | 4k | 5 | 18.45 | 4.12 | 0.04 | 2.44 | 11.34 | 3349 | 450 |
| 5× Saturation [fusion on] | 4k | 1 | 18.24 | 4.30 | 0.04 | 1.97 | 11.37 | 4136 | 455 |
| 10× Saturation [fusion off] | 4k | 10 | 18.67 | 4.19 | 0.04 | 2.92 | 11.21 | 2803 | 444 |
| 10× Saturation [fusion on] | 4k | 1 | 18.45 | 4.26 | 0.04 | 2.30 | 11.33 | 3546 | 450 |
| 20× Saturation [fusion off] | 4k | 20 | 20.97 | 4.38 | 0.05 | 4.54 | 11.32 | 1807 | 396 |
| 20× Saturation [fusion on] | 4k | 1 | 19.01 | 4.28 | 0.05 | 2.91 | 11.27 | 2807 | 436 |
| 40× Saturation [fusion off] | 4k | 40 | 24.31 | 4.27 | 0.07 | 8.27 | 11.21 | 994 | 341 |
| 40× Saturation [fusion on] | 4k | 2 | 20.33 | 4.22 | 0.07 | 4.21 | 11.24 | 1939 | 408 |
| 1× Exposure [fusion off] | 4k | 1 | 17.41 | 4.21 | 0.02 | 1.21 | 11.40 | 6733 | 477 |
| 2× Exposure [fusion off] | 4k | 2 | 19.13 | 4.63 | 0.04 | 1.93 | 12.00 | 4222 | 434 |
| 2× Exposure [fusion on] | 4k | 1 | 19.49 | 4.71 | 0.04 | 2.07 | 12.06 | 3916 | 425 |
| 5× Exposure [fusion off] | 4k | 5 | 19.31 | 4.55 | 0.04 | 2.46 | 11.67 | 3316 | 430 |
| 5× Exposure [fusion on] | 4k | 1 | 19.43 | 4.38 | 0.04 | 2.66 | 11.51 | 3065 | 427 |
| 10× Exposure [fusion off] | 4k | 10 | 19.48 | 4.32 | 0.04 | 3.14 | 11.37 | 2608 | 426 |
| 10× Exposure [fusion on] | 4k | 1 | 19.85 | 4.47 | 0.05 | 3.06 | 11.56 | 2670 | 418 |
| 20× Exposure [fusion off] | 4k | 20 | 23.08 | 4.73 | 0.06 | 5.98 | 11.67 | 1373 | 359 |
| 20× Exposure [fusion on] | 4k | 1 | 20.39 | 4.40 | 0.06 | 3.95 | 11.40 | 2070 | 407 |
| 40× Exposure [fusion off] | 4k | 40 | 26.49 | 4.35 | 0.08 | 10.27 | 11.31 | 801 | 313 |
| 40× Exposure [fusion on] | 4k | 2 | 23.97 | 4.41 | 0.09 | 7.65 | 11.43 | 1073 | 346 |
| 1× Temperature [fusion off] | 4k | 1 | 17.29 | 4.38 | 0.03 | 1.10 | 11.43 | 7329 | 480 |
| 2× Temperature [fusion off] | 4k | 2 | 18.42 | 4.52 | 0.04 | 1.97 | 11.47 | 4132 | 450 |
| 2× Temperature [fusion on] | 4k | 1 | 18.45 | 4.32 | 0.03 | 2.26 | 11.45 | 3613 | 450 |
| 5× Temperature [fusion off] | 4k | 5 | 20.56 | 4.36 | 0.05 | 4.22 | 11.53 | 1942 | 403 |
| 5× Temperature [fusion on] | 4k | 1 | 19.12 | 4.41 | 0.05 | 2.65 | 11.62 | 3075 | 434 |
| 10× Temperature [fusion off] | 4k | 10 | 20.18 | 4.39 | 0.05 | 4.06 | 11.50 | 2019 | 411 |
| 10× Temperature [fusion on] | 4k | 1 | 20.22 | 4.34 | 0.06 | 3.52 | 11.63 | 2320 | 410 |
| 20× Temperature [fusion off] | 4k | 20 | 21.83 | 4.11 | 0.06 | 6.07 | 11.37 | 1354 | 380 |
| 20× Temperature [fusion on] | 4k | 1 | 21.24 | 4.25 | 0.06 | 5.11 | 11.41 | 1604 | 390 |
| 40× Temperature [fusion off] | 4k | 40 | 26.72 | 4.34 | 0.08 | 10.49 | 11.46 | 784 | 310 |
| 40× Temperature [fusion on] | 4k | 2 | 24.27 | 4.47 | 0.09 | 7.78 | 11.54 | 1054 | 342 |

wrote Benchmarks/results/diagnosis-alu-vs-bandwidth.json
