// Inputs.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Foundation
import ImageIO
import Prism

struct Resolution {
    var name: String
    var width: Int
    var height: Int
    var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Standard sizes. "large" stands in for a full-resolution camera photo (24 MP, 3:2).
let standardResolutions = [
    Resolution(name: "1080p", width: 1920, height: 1080),
    Resolution(name: "4k", width: 3840, height: 2160),
    Resolution(name: "large", width: 6000, height: 4000),
]

/// Deterministic synthetic image with photograph-like statistics: smooth low-frequency
/// gradients, hard edges (rectangles and diagonals), fine-grain noise, and a soft alpha ramp
/// near one border. It is **not** a real photograph; pass `--image` to benchmark one.
///
/// GPU compute cost here is independent of pixel values (no data-dependent branching in
/// any kernel), so a synthetic image measures the same GPU work as a photo of equal size.
func makeSyntheticImage(width: Int, height: Int) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var rng: UInt32 = 0x1234_5678
    bytes.withUnsafeMutableBufferPointer { px in
        for y in 0..<height {
            let fy = Double(y) / Double(height)
            for x in 0..<width {
                let fx = Double(x) / Double(width)
                rng = rng &* 1_664_525 &+ 1_013_904_223
                let noise = Double(rng >> 24) / 255 - 0.5
                var r = 0.5 + 0.4 * sin(fx * 9 + fy * 3), g = 0.5 + 0.4 * sin(fy * 7 - fx * 2), b = 0.3 + 0.6 * fx * fy
                if (x / 97 + y / 61) % 7 == 0 { r = 1 - r; g = 0.9; b = 0.1 }       // hard-edged tiles
                if abs(x - y * width / height) < 3 { r = 1; g = 1; b = 1 }           // diagonal line
                let a = y < height / 20 ? Double(y) / Double(height / 20) : 1.0      // alpha ramp, top border
                let i = (y * width + x) * 4
                for (c, v) in [r, g, b].enumerated() {
                    px[i + c] = UInt8(max(0, min(255, (v + noise * 0.05) * 255 * a)))   // premultiplied
                }
                px[i + 3] = UInt8(a * 255)
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func loadImage(at path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
