// Resize.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include "Common.h"

struct ResizeParams { float scaleX; float scaleY; };   // source size / destination size

/// Bilinear resize with pixel-center alignment: destination texel centers map to
/// source coordinates (d + 0.5) * scale - 0.5; samples outside clamp to the border texel.
/// Weights are computed in float rather than via a hardware sampler so results are exact
/// and testable. No prefiltering: large downscales alias (see Documentation).
kernel void prism_resize_bilinear(texture2d<float, access::read>  src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant ResizeParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    float2 pos = (float2(gid) + 0.5f) * float2(p.scaleX, p.scaleY) - 0.5f;
    float2 base = floor(pos);
    float2 t = pos - base;
    int2 hi = int2(src.get_width() - 1, src.get_height() - 1);
    int2 i0 = clamp(int2(base), int2(0), hi);
    int2 i1 = clamp(int2(base) + 1, int2(0), hi);
    float4 top = mix(src.read(uint2(i0.x, i0.y)), src.read(uint2(i1.x, i0.y)), t.x);
    float4 bottom = mix(src.read(uint2(i0.x, i1.y)), src.read(uint2(i1.x, i1.y)), t.x);
    dst.write(mix(top, bottom, t.y), gid);
}
