# Color handling in Prism

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

This document states what Prism currently does and does not guarantee. It is updated
whenever the implementation changes; nothing here is aspirational.

## Pixel representation

| Property | `Precision.standard` | `Precision.high` |
|---|---|---|
| Texture format | `rgba8Unorm` | `rgba16Float` (IEEE half) |
| Alpha | **Premultiplied** | **Premultiplied** |
| Transfer function | **sRGB-encoded** (gamma) values in a *non-sRGB* texture format, so the GPU does no implicit conversion | Same: sRGB-encoded values, in extended range |
| Primaries / white point | sRGB (Rec. 709, D65) | sRGB, extended range |
| Kernel arithmetic | 32-bit float | 32-bit float |

`bgra8Unorm` textures are also accepted on the texture path (processed like `rgba8Unorm`).

## Precision (`Precision.high`)

What it is: **half-float storage** between passes: 1 sign bit, 5 exponent bits, 10 stored mantissa
bits, i.e. 11 significant bits. It is *not* 16-bit integer precision. Over [0, 1] its step size is
about 2⁻¹¹ (0.0005, or ~0.12 of an 8-bit step) near 1.0 and much finer near black, versus 1/255 = 0.0039
everywhere for 8-bit. Kernels still compute in 32-bit float; only what is stored between passes (and
imported/exported) changes.

What was measured (see `PrecisionTests`; all against a Double-precision reference that applies the
same operations with no rounding between them):

- A single operation's error is at most 1.5×10⁻³ (0.4 of an 8-bit step), including blur.
- A 20-stage Exposure/Contrast chain, every stage stored: **2.3 LSB** (in 8-bit units) in half-float
  versus **10.8 LSB** for 8-bit storage: about 4.7× closer. With fusion the 20 stages become one pass
  and the half-float result is **0.3 LSB** from exact.
- Banding: darkening a 256-level ramp by 5 stops and restoring it leaves only 50 distinct levels and
  15 LSB of error in 8-bit; half-float restores it exactly (0 LSB).
- 16-bit integer sources keep information 8-bit storage discards: 64 red values spaced 0.0006 apart
  stay distinct (60+ of 64) in half-float, versus 11 in 8-bit. Import error is at most 6×10⁻⁴.

What it costs (measured on one machine): twice the texture memory; on the texture path GPU time
for a 5-stage pipeline +13% (2.91 → 3.29 ms) and a 10-stage +27% (5.90 → 7.51 ms) at 4K, with no difference for a fused
per-pixel chain or a blur alone (those are arithmetic-bound, not bandwidth-bound). Through `CGImage` the 64-bit import and
export are the main cost (a 5-stage 4K render: 7.3 ms in 8-bit, 14.2 ms in float16; import alone goes 1.9 → 7.6 ms). At 24 MP the float16 texture path's wall time exceeds its GPU time by ~5 ms (13.7 vs 8.6 ms for 5-stage), reproducibly; the cause is not yet understood. Results: `Benchmarks/results/after-5-precision.*`.

What it does *not* do:

- **It is not an HDR or wide-gamut pipeline.** Color operations (Exposure, Contrast, Saturation,
  Temperature, Vignette, LUT) clamp their result to [0, 1]. Blur, sharpen and resize do not clamp, so
  out-of-range values (above 1, or negative) pass through them (tested), but the first color operation
  clips them.
- Wide-gamut `CGImage` sources are converted by CoreGraphics to *extended* sRGB, which keeps
  out-of-gamut colors as values outside [0, 1] instead of clipping them on import. Prism then clips
  them at the first color operation. No gamut mapping is done.
- The `CGImage` returned for `.high` has 16-bit float components in extended sRGB, premultiplied. Convert
  it yourself for 8-bit output (draw it into an 8-bit `CGContext`). CoreGraphics' float → 8-bit
  conversion of *partly transparent* pixels can land 1 LSB from the value Prism holds; opaque pixels
  round-trip exactly (tested).
- Handing a `.high` result (a 16-bit *float* image) straight to ImageIO's PNG writer produces an 8-bit
  file, and in a test partly transparent pixels deviated by up to 11 LSB from the same pipeline rendered at
  8-bit (opaque pixels: within 1 LSB); the cause is not identified. Redrawing the result into a 16-bit
  *integer* premultiplied sRGB `CGContext` first (what Prism Studio's `ImageExport` does) writes a true
  16-bit PNG within 1 LSB of the 8-bit render, transparency included.
- 32-bit float storage is not supported (`rgba32Float` textures are rejected).

## Import and export

### `CGImage`

- A `CGImage` that is already **8-bit RGBA, premultiplied alpha last, big-endian component
  order, sRGB, no decode array** is uploaded byte-for-byte from its backing store, with no
  intermediate bitmap. This is exactly what Prism produces on export, so round trips are
  lossless.
- Any other layout is redrawn by CoreGraphics into an sRGB, premultiplied RGBA8 bitmap (blend
  mode `copy`, so transparent pixels are preserved exactly): BGRA, opaque RGBX, straight alpha
  (premultiplied on import, rounded), greyscale (replicated to RGB). **Any source color space
  is converted to sRGB by CoreGraphics**, including Display P3 and other wide-gamut spaces.
  Out-of-gamut colors are therefore clipped to sRGB on import (tested: P3 red becomes
  sRGB (255, 0, 0)); Prism does not preserve wide color today.
- With `Precision.standard`, 16-bit and HDR sources are quantized to 8 bits on import. With
  `Precision.high` they are imported at half-float precision (see above).
- `CGImage` output is tagged sRGB, premultiplied-last.
- An sRGB 8-bit image that goes in and comes out with no operations is bit-exact (tested).

### `MTLTexture`

`ImagePipeline.render(_ texture:into:using:)` takes and returns textures without any
conversion, so **the caller is responsible for the contents being what Prism expects**:

- Pixel format `rgba8Unorm`, `bgra8Unorm` or `rgba16Float` (other formats are rejected). The
  pipeline runs in the texture's own format, so an `rgba16Float` texture is processed at
  `Precision.high`.
- **Premultiplied alpha** and **sRGB-encoded** values. Prism does not convert, and has no way
  to check. A texture holding linear light, straight alpha, or another color space will be
  processed as if it were sRGB premultiplied and give wrong results, with no error.
- `bgra8Unorm` is handled by the hardware's channel mapping: kernels see logical RGBA, and
  the output has the same format as the input (tested to equal the `rgba8Unorm` result).
- The output has the input's pixel format and the same conventions.

## Where each operation does its math

Color operations are only meaningful on *straight* (unpremultiplied) color, so they divide
by alpha, operate, clamp to 0…1, and re-multiply. Spatial operations work directly on
premultiplied values, which is the correct space for averaging.

| Operation | Space | Notes |
|---|---|---|
| Exposure | Scene-linear | decode sRGB → multiply by 2^EV → encode. Physically meaningful. |
| Temperature | Scene-linear | Gains on R and B only. An artistic control, **not** a Kelvin white-point conversion. |
| Vignette | Scene-linear | Scales light, like a lens falloff. |
| Contrast | sRGB-encoded | Pivot at 0.5 *encoded*, i.e. ≈ 21% linear. Matches common editor behavior, not a photometric operation. |
| Saturation | sRGB-encoded | Rec. 709 luma weights applied to *encoded* values, so the luma is not true luminance. |
| LUT | sRGB-encoded | Straight color in, straight color out. The LUT must be authored for sRGB-encoded 0…1 input. |
| Gaussian blur / Sharpen | Encoded, premultiplied | Averages encoded values. This is the default in most image editors but is **not** gamma-correct: bright/dark edges blur slightly darker than a linear-light blur. Linear-light blur is a possible future option. |
| Resize (bilinear) | Encoded, premultiplied | Same caveat as blur. Bilinear does not prefilter; large downscales alias. |

All clamping is to 0…1. There is no HDR / over-range headroom.

## What Prism does not do

- No ICC profile handling beyond CoreGraphics' conversion to sRGB on import.
- No wide-gamut or HDR processing (see "Precision" for exactly what `.high` does), and no claim of
  professional color accuracy.
- No tone mapping, gamut mapping, or chromatic adaptation.
- No dithering when quantizing to 8 bits. With `Precision.standard`, intermediate textures are
  rounded to 8 bits between stages, so long pipelines accumulate error (10.8 LSB over the measured
  20-stage chain); use `Precision.high` or let fusion merge per-pixel stages to reduce it.

## How correctness is checked

Every operation is compared against a Double-precision CPU implementation of the same
definition on deterministic images (odd sizes, 1×1, transparent pixels, extreme
parameters). The enforced tolerance is **1 LSB (of 255)** for single operations; it
quantifies GPU float error plus 8-bit rounding, not perceptual accuracy against an
external standard. Agreement with another tool (e.g. Core Image) is a separate validation
that is not yet part of the suite.
