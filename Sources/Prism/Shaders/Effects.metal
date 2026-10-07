// Effects.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include "Pointwise.h"

struct VignetteParams { float amount; float radius; };

/// Vignette: darkens toward the frame corners by scaling scene-linear light.
/// gain = 1 - amount * smoothstep(radius, 1, d); see `apply_vignette`.
kernel void prism_vignette(texture2d<float, access::read>  src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant VignetteParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    float2 size = float2(src.get_width(), src.get_height());
    dst.write(float4(apply_vignette(unpremultiply(px), gid, size, p.amount, p.radius) * px.a, px.a), gid);
}

struct LUTParams { int size; float intensity; };

/// 3D LUT with manual trilinear interpolation (8 exact reads, no hardware filtering).
/// Input: straight sRGB-encoded color in [0,1]; the lattice spans 0...1 inclusive, so
/// input v maps to lattice coordinate v * (size - 1). Texture x/y/z = r/g/b.
kernel void prism_lut(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      texture3d<float, access::read>  lut [[texture(2)]],
                      constant LUTParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 px = src.read(gid);
    float3 c = saturate(unpremultiply(px));
    float3 pos = c * float(p.size - 1);
    float3 base = floor(pos);
    float3 t = pos - base;
    uint3 i0 = uint3(base);
    uint3 i1 = min(i0 + 1, uint3(p.size - 1));

    float3 c00 = mix(lut.read(uint3(i0.x, i0.y, i0.z)).rgb, lut.read(uint3(i1.x, i0.y, i0.z)).rgb, t.x);
    float3 c10 = mix(lut.read(uint3(i0.x, i1.y, i0.z)).rgb, lut.read(uint3(i1.x, i1.y, i0.z)).rgb, t.x);
    float3 c01 = mix(lut.read(uint3(i0.x, i0.y, i1.z)).rgb, lut.read(uint3(i1.x, i0.y, i1.z)).rgb, t.x);
    float3 c11 = mix(lut.read(uint3(i0.x, i1.y, i1.z)).rgb, lut.read(uint3(i1.x, i1.y, i1.z)).rgb, t.x);
    float3 graded = mix(mix(c00, c10, t.y), mix(c01, c11, t.y), t.z);

    float3 out = saturate(mix(c, graded, p.intensity));
    dst.write(float4(out * px.a, px.a), gid);
}
