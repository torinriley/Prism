// Sharpen.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include "Common.h"

struct UnsharpParams { float amount; };

/// Unsharp mask: original + amount * (original - blurred), on premultiplied values.
/// Color is clamped to [0, alpha] so the result stays a valid premultiplied pixel.
kernel void prism_unsharp_combine(texture2d<float, access::read>  original [[texture(0)]],
                                  texture2d<float, access::read>  blurred  [[texture(1)]],
                                  texture2d<float, access::write> dst      [[texture(2)]],
                                  constant UnsharpParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    float4 o = original.read(gid);
    float4 b = blurred.read(gid);
    float3 rgb = clamp(o.rgb + p.amount * (o.rgb - b.rgb), 0.0f, o.a);
    dst.write(float4(rgb, o.a), gid);
}
