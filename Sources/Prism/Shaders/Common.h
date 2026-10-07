// Common.h — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#pragma once
#include <metal_stdlib>
using namespace metal;

// Prism pixel convention: premultiplied alpha, sRGB-encoded RGB (see Documentation/COLOR.md).
// Math that is only meaningful on straight color unpremultiplies first and re-premultiplies after.

inline float3 srgb_to_linear(float3 c) {
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

inline float3 linear_to_srgb(float3 c) {
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, c * 12.92f, c <= 0.0031308f);
}

inline float3 unpremultiply(float4 p) { return p.a > 0.0f ? p.rgb / p.a : float3(0.0f); }

constant float3 kLuma709 = float3(0.2126f, 0.7152f, 0.0722f);
