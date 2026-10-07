// ImageExportTests.swift — Prism Studio
// Author: Torin Etheridge
// Date: October 7, 2026

import CoreGraphics
import Foundation
import ImageIO
import Prism
import Testing
@testable import PrismStudio

/// A test image with every alpha from fully transparent to opaque (premultiplied RGBA8).
private func testImage(width: Int = 64, height: Int = 32) -> CGImage {
    var bytes = [UInt8]()
    for y in 0..<height { for x in 0..<width {
        let a = UInt8((x * 37 + y * 11) % 256)
        let scale = { (v: Int) in UInt8(Int(a) * (v % 256) / 255) }
        bytes += [scale(x * 13 + 5), scale(y * 29 + 3), scale(x * y + 101), a]
    } }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// 8-bit premultiplied sRGB RGBA of any image.
private func rgba8(_ image: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    out.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return out
}

private let pipeline = ImagePipeline { Exposure(0.3); Contrast(1.1) }

@Suite("Studio image export")
struct ImageExportTests {
    @Test("A half-float render exports as a true 16-bit PNG that matches the 8-bit render within 1 LSB, transparency included")
    func halfFloatExport() async throws {
        let input = testImage()
        let reference = rgba8(try await pipeline.render(input, precision: .standard))
        let high = try await pipeline.render(input, precision: .high)
        #expect(high.bitmapInfo.contains(.floatComponents))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prism-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageExport.writePNG(high, to: url))

        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, options))
        let back = try #require(CGImageSourceCreateImageAtIndex(source, 0, options))
        #expect(back.bitsPerComponent == 16, "the file keeps 16 bits per channel")
        let pixels = rgba8(back)
        var worst = 0
        for i in 0..<pixels.count { worst = max(worst, abs(Int(pixels[i]) - Int(reference[i]))) }
        #expect(worst <= 1, "max difference \(worst) LSB (was 11 when handed to ImageIO as 16-bit float)")
    }

    @Test("8-bit images are written unchanged")
    func eightBitPassesThrough() throws {
        let image = testImage()
        #expect(ImageExport.pngReady(image) === image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prism-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageExport.writePNG(image, to: url))
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, options))
        let back = try #require(CGImageSourceCreateImageAtIndex(source, 0, options))
        #expect(rgba8(back) == rgba8(image))
    }

    @Test("Writing to an unwritable location reports failure instead of crashing")
    func unwritable() {
        #expect(!ImageExport.writePNG(testImage(), to: URL(fileURLWithPath: "/nonexistent-directory/out.png")))
    }

    @Test("Launch arguments: flags a launcher adds are ignored, and only existing files count")
    func launchArguments() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prism-arg-\(UUID().uuidString).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(ImageExport.imagePath(in: ["PrismStudio"]) == nil)
        #expect(ImageExport.imagePath(in: ["PrismStudio", file.path]) == file.path)
        #expect(ImageExport.imagePath(in: ["PrismStudio", "-NSDocumentRevisionsDebugMode", "YES", file.path]) == file.path)
        #expect(ImageExport.imagePath(in: ["PrismStudio", "-ApplePersistenceIgnoreState", "/no/such/file.png"]) == nil)
    }
}
