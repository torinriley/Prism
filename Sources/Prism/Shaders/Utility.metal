// Utility.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include <metal_stdlib>
using namespace metal;

/// Inverts color of a premultiplied-alpha pixel: premultiplied (1 - c/a) * a == a - c.
kernel void prism_invert(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    dst.write(float4(c.a - c.rgb, c.a), gid);
}

struct MixParams { float t; };

/// Linear interpolation of two premultiplied images: a*(1-t) + b*t.
kernel void prism_mix(texture2d<float, access::read>  a   [[texture(0)]],
                      texture2d<float, access::read>  b   [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]],
                      constant MixParams &p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    dst.write(mix(a.read(gid), b.read(gid), p.t), gid);
}
