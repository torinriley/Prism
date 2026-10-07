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
