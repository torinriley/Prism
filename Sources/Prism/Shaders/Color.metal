// Color.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include "Pointwise.h"

// Pixels are premultiplied, sRGB-encoded. Each kernel here is a thin wrapper that unpremultiplies,
// calls the shared function in Pointwise.h, and re-premultiplies.

struct ExposureParams { float gain; };   // linear multiplier, 2^EV

/// Exposure: scales scene-linear light by 2^EV.
kernel void prism_exposure(texture2d<float, access::read>  src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant ExposureParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    dst.write(float4(apply_exposure(unpremultiply(px), p.gain) * px.a, px.a), gid);
}

struct ContrastParams { float factor; };

/// Contrast: scales distance from mid-grey (0.5) in sRGB-encoded space.
kernel void prism_contrast(texture2d<float, access::read>  src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant ContrastParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    dst.write(float4(apply_contrast(unpremultiply(px), p.factor) * px.a, px.a), gid);
}

struct SaturationParams { float factor; };

/// Saturation: scales distance from Rec.709 luma, computed on sRGB-encoded values.
kernel void prism_saturation(texture2d<float, access::read>  src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant SaturationParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    dst.write(float4(apply_saturation(unpremultiply(px), p.factor) * px.a, px.a), gid);
}

struct TemperatureParams { float redGain; float blueGain; };

/// Temperature: per-channel gains on scene-linear straight color (red and blue only).
kernel void prism_temperature(texture2d<float, access::read>  src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant TemperatureParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    dst.write(float4(apply_temperature(unpremultiply(px), p.redGain, p.blueGain) * px.a, px.a), gid);
}

// MARK: Fused chain

enum PointwiseCode { kExposure = 0, kContrast = 1, kSaturation = 2, kTemperature = 3, kVignette = 4 };

/// One step of a fused chain. `a` and `b` carry the operation's parameters in the order of its
/// standalone kernel's uniforms (Vignette: amount, radius).
struct PointOp { int code; float a; float b; float unused; };
struct ChainParams { int count; };

/// Runs a list of per-pixel operations in registers: one read and one write per pixel,
/// whatever the chain length. The op index is uniform across the grid, so the switch does not
/// diverge.
kernel void prism_pointwise_chain(texture2d<float, access::read>  src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant ChainParams &p [[buffer(0)]],
                                  constant PointOp *ops [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    float3 c = unpremultiply(px);
    float2 size = float2(src.get_width(), src.get_height());
    for (int i = 0; i < p.count; ++i) {
        PointOp op = ops[i];
        switch (op.code) {
            case kExposure:    c = apply_exposure(c, op.a); break;
            case kContrast:    c = apply_contrast(c, op.a); break;
            case kSaturation:  c = apply_saturation(c, op.a); break;
            case kTemperature: c = apply_temperature(c, op.a, op.b); break;
            case kVignette:    c = apply_vignette(c, gid, size, op.a, op.b); break;
        }
    }
    dst.write(float4(c * px.a, px.a), gid);
}
