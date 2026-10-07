// CGImageInterop.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import CoreGraphics
import Metal

/// CGImage ↔ MTLTexture conversion.
///
/// Phase 1 contract (documented fully in COLOR.md later):
/// - Textures are `rgba8Unorm`, **premultiplied** alpha, **sRGB-encoded** (gamma) values.
/// - Source images in any color space are converted to sRGB by CoreGraphics on upload.
/// - No sRGB↔linear conversion happens here; kernels decide what encoding they need.
enum CGImageInterop {
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue

    static func makeTexture(from image: CGImage, context: MetalContext, precision: Precision = .standard) throws -> any MTLTexture {
        let texture = try context.makeTexture(width: image.width, height: image.height, pixelFormat: precision.pixelFormat)
        try upload(image, to: texture)
        return texture
    }

    /// Overwrites every pixel of `texture` (`rgba8Unorm` or `rgba16Float`, exactly the image's size).
    ///
    /// Images already in Prism's native layout (see ``isNativeLayout``) are uploaded straight
    /// from their backing store, with no intermediate bitmap. Anything else is redrawn through
    /// CoreGraphics, which converts layout, alpha and color space to sRGB premultiplied RGBA8.
    static func upload(_ image: CGImage, to texture: any MTLTexture) throws {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else {
            throw PrismError.unsupportedImage(reason: "image has zero size")
        }
        precondition(texture.width == width && texture.height == height)
        if texture.pixelFormat == .rgba16Float { return try uploadFloat16(image, to: texture) }
        precondition(texture.pixelFormat == .rgba8Unorm)

        if isNativeLayout(image), let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * (height - 1) + width * 4 {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: CFDataGetBytePtr(data), bytesPerRow: image.bytesPerRow)
            return
        }
        try uploadByRedrawing(image, to: texture)
    }

    /// True for 8-bit RGBA, premultiplied alpha last, big-endian component order, sRGB, no
    /// decode array: byte-for-byte what Prism stores in a texture.
    static func isNativeLayout(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.bytesPerRow >= image.width * 4,
              image.alphaInfo == .premultipliedLast,
              image.byteOrderInfo == .order32Big || image.byteOrderInfo == .orderDefault,
              image.decode == nil,
              let space = image.colorSpace, space.name == CGColorSpace.sRGB
        else { return false }
        return true
    }

    // MARK: 16-bit float

    static let float16BitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue

    /// Extended-range sRGB: sRGB's transfer curve and primaries, with values outside [0, 1] allowed.
    /// Inside [0, 1] it is numerically identical to sRGB, so 8-bit sRGB sources import as v / 255.
    static var extendedSRGB: CGColorSpace? { CGColorSpace(name: CGColorSpace.extendedSRGB) }

    /// 16-bit float, premultiplied last, little-endian, extended sRGB: what an `rgba16Float`
    /// texture holds, so such an image uploads without a redraw.
    static func isNativeFloat16Layout(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 16, image.bitsPerPixel == 64, image.bytesPerRow >= image.width * 8,
              image.alphaInfo == .premultipliedLast, image.bitmapInfo.contains(.floatComponents),
              image.byteOrderInfo == .order16Little, image.decode == nil,
              let space = image.colorSpace, space.name == CGColorSpace.extendedSRGB
        else { return false }
        return true
    }

    /// Imports any `CGImage` as 16-bit float premultiplied extended sRGB. 8-bit sRGB sources become
    /// v / 255; 16-bit and float sources keep their precision; other color spaces are converted by
    /// CoreGraphics (out-of-gamut colors are kept as values outside [0, 1], not clipped).
    static func uploadFloat16(_ image: CGImage, to texture: any MTLTexture) throws {
        let width = image.width, height = image.height
        if isNativeFloat16Layout(image), let data = image.dataProvider?.data,
           CFDataGetLength(data) >= image.bytesPerRow * (height - 1) + width * 8 {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: CFDataGetBytePtr(data), bytesPerRow: image.bytesPerRow)
            return
        }
        guard let space = extendedSRGB,
              let cg = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                space: space, bitmapInfo: float16BitmapInfo)
        else {
            throw PrismError.unsupportedImage(reason: "could not create a \(width)×\(height) 16-bit float bitmap context")
        }
        cg.setBlendMode(.copy)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = cg.data else {
            throw PrismError.unsupportedImage(reason: "bitmap context has no backing store")
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: width * 8)
    }

    /// The general path: draw into an sRGB premultiplied RGBA8 bitmap, then copy to the texture.
    static func uploadByRedrawing(_ image: CGImage, to texture: any MTLTexture) throws {
        let width = image.width, height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
        else {
            throw PrismError.unsupportedImage(reason: "could not create a \(width)×\(height) bitmap context")
        }
        // `.copy` keeps transparent pixels exactly as the source specifies instead of
        // compositing over an empty (transparent black) destination.
        cg.setBlendMode(.copy)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = cg.data else {
            throw PrismError.unsupportedImage(reason: "bitmap context has no backing store")
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: width * 4)
    }

    /// Reads `texture` back into a CGImage. The caller must ensure GPU writes have completed.
    ///
    /// The pixels are read once, straight into a buffer the image then owns: no zero-fill, no
    /// second copy.
    static func makeCGImage(from texture: any MTLTexture) throws -> CGImage {
        let isFloat16 = texture.pixelFormat == .rgba16Float
        guard texture.pixelFormat == .rgba8Unorm || isFloat16 else {
            throw PrismError.unsupportedImage(reason: "cannot export pixel format \(texture.pixelFormat)")
        }
        let bytesPerPixel = isFloat16 ? 8 : 4
        let size = texture.width * texture.height * bytesPerPixel
        guard let buffer = malloc(size) else {
            throw PrismError.unsupportedImage(reason: "could not allocate \(size) bytes for the output image")
        }
        texture.getBytes(
            buffer, bytesPerRow: texture.width * bytesPerPixel,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        guard let colorSpace = isFloat16 ? extendedSRGB : CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in
                  free(UnsafeMutableRawPointer(mutating: data))
              }),
              let image = CGImage(
                width: texture.width, height: texture.height,
                bitsPerComponent: isFloat16 ? 16 : 8, bitsPerPixel: bytesPerPixel * 8,
                bytesPerRow: texture.width * bytesPerPixel, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: isFloat16 ? float16BitmapInfo : bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            free(buffer)
            throw PrismError.unsupportedImage(reason: "could not construct CGImage")
        }
        return image
    }

    /// Raw bytes (4 per pixel for 8-bit formats, 8 for `rgba16Float`), row-major, top row first.
    static func readPixels(from texture: any MTLTexture) -> [UInt8] {
        let bytesPerPixel = texture.pixelFormat == .rgba16Float ? 8 : 4
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * bytesPerPixel)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: texture.width * bytesPerPixel,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
}
