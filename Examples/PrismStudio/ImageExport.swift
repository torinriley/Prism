// ImageExport.swift — Prism Studio
// Author: Torin Etheridge
// Date: October 7, 2026

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Writing Prism's results to disk.
///
/// A `Precision.high` render is a 16-bit *float* `CGImage`. Handing that straight to ImageIO writes
/// an 8-bit PNG whose partly transparent pixels deviate by up to 11 LSB from the 8-bit render of the
/// same pipeline (measured). Redrawing it into a 16-bit *integer* premultiplied sRGB bitmap first gives
/// a true 16-bit PNG, with opaque pixels exact and partly transparent ones within 1 LSB.
enum ImageExport {
    /// An image ImageIO can write faithfully: 8-bit images pass through unchanged; 16-bit float images
    /// are converted to 16-bit integer sRGB (values outside [0, 1] are clamped, as PNG requires).
    static func pngReady(_ image: CGImage) -> CGImage? {
        guard image.bitsPerComponent == 16, image.bitmapInfo.contains(.floatComponents) else { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Writes `image` as a PNG. Returns `false` if conversion or writing fails.
    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let exportable = pngReady(image),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, exportable, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// The first launch argument that names an existing file, ignoring flags a launcher may add
    /// (Xcode passes some, such as `-NSDocumentRevisionsDebugMode`).
    static func imagePath(in arguments: [String]) -> String? {
        arguments.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
    }
}
