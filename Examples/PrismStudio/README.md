# Prism Studio

> **Author:** Torin Etheridge · **Updated:** October 6, 2026

Prism Studio is a restrained macOS profiling shell for the Prism engine, not a photo editor.

```sh
swift run PrismStudio
```

For a repeatable profiling session, pass an image path to open it immediately:

```sh
swift run PrismStudio -- /path/to/image.heic
```

Open or drop an image, adjust the seven engine controls, and hover or click the comparison button to
inspect the original. The right-hand inspector is populated from `RenderMetrics`; it shows the graph
that actually executed rather than a separately maintained UI model. Detailed instrumentation is
enabled so node timings are available. Use the precision toggle to compare 8-bit and half-float
intermediates, and Export to write the current result as PNG.

Parameter changes are debounced by 45 ms and cancel work that has not reached GPU submission. Once a
Metal command buffer is submitted it cannot be cancelled; generation checks prevent an older result
from replacing a newer one in the UI.

## Notes and known issues

- **Instrumentation level.** Studio always runs the renderer at `.detailed` (the inspector says so) so every pass has a GPU
  time. That encodes each pass in its own compute encoder, which is not how `.standard` encodes the
  same work. Use the inspector to see *which passes ran and their relative cost*, and `prism-bench`
  for timings of the default path.
- **Cold first frame.** The first render after loading an image compiles pipelines and allocates
  textures, so the inspector shows non-zero "compiled", no texture reuse and a larger frame time.
  Move a slider for steady-state values.
- **Export.** With the 16-bit float toggle on, the render result is a 16-bit float `CGImage`. Handing that
  directly to ImageIO wrote an 8-bit PNG whose partly transparent pixels deviated by up to 11 LSB from
  the 8-bit render (cause not identified). Studio therefore redraws it into a 16-bit integer
  premultiplied sRGB bitmap first (`ImageExport`), which writes a true 16-bit PNG that matches the 8-bit
  render within 1 LSB, transparency included (covered by `PrismStudioTests`). 8-bit renders are written
  unchanged. Values outside [0, 1] are clamped, as PNG requires.
- **Launch arguments.** The first argument that names an existing file is opened; flags a launcher adds
  (Xcode passes some) are ignored.
- **Conversion cost.** Studio uses the `CGImage` path, so every frame pays image import and export
  (about 2 ms each at 4K in 8-bit, more in half-float) on top of GPU work. Holding the image as an
  `MTLTexture` and displaying through a Metal view would remove that; it is not implemented.

