// Precision.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Metal

/// How pixel values are stored while a pipeline runs.
///
/// Every kernel does its arithmetic in 32-bit float regardless; precision controls what is
/// *stored* between passes and, for `CGImage`s, at import and export.
public enum Precision: Sendable, Equatable {
    /// 8 bits per channel (`rgba8Unorm`). Every pass rounds to 8 bits, so long chains accumulate
    /// rounding error (see ``high``). The result is an 8-bit sRGB `CGImage`.
    case standard

    /// 16-bit **floating point** per channel (`rgba16Float`, IEEE half: 11 significant bits,
    /// about 3 decimal digits; *not* 16-bit integer precision), in extended-range sRGB.
    ///
    /// - Intermediate results keep about 2.7 more bits than 8-bit storage over [0, 1], and far
    ///   finer steps near black, so chains of operations stay close to the exact result.
    /// - 16-bit and float sources are imported without being reduced to 8 bits.
    /// - Costs twice the texture memory and memory traffic.
    /// - The `CGImage` result has 16-bit float components (extended sRGB, premultiplied). To get an
    ///   8-bit image, draw it into an 8-bit `CGContext`.
    /// - Color operations still clamp to [0, 1]; blur, sharpen and resize carry out-of-range values
    ///   through. It does not make Prism an HDR or wide-gamut pipeline (see COLOR.md).
    case high

    var pixelFormat: MTLPixelFormat {
        switch self {
        case .standard: .rgba8Unorm
        case .high: .rgba16Float
        }
    }
}
