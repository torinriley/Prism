// Pointwise.h — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#pragma once
#include "Common.h"

// Per-pixel color operations on *straight* (unpremultiplied) sRGB-encoded color, each clamped
// to [0, 1]. These are the single definition of each operation's math: the standalone
// kernels and the fused chain kernel both call them, so a fused chain cannot differ from the
// same operations run one pass at a time except for the 8-bit rounding between passes.

inline float3 apply_exposure(float3 c, float gain) {
    return saturate(linear_to_srgb(max(srgb_to_linear(c) * gain, 0.0f)));
}

inline float3 apply_contrast(float3 c, float factor) {
    return saturate((c - 0.5f) * factor + 0.5f);
}

inline float3 apply_saturation(float3 c, float factor) {
    float luma = dot(c, kLuma709);
    return saturate(luma + (c - luma) * factor);
}

inline float3 apply_temperature(float3 c, float redGain, float blueGain) {
    return saturate(linear_to_srgb(srgb_to_linear(c) * float3(redGain, 1.0f, blueGain)));
}

/// d is 0 at the center and 1 at the corners (normalized per axis).
inline float3 apply_vignette(float3 c, uint2 gid, float2 size, float amount, float radius) {
    float2 uv = (float2(gid) + 0.5f) / size;
    float d = length(uv - 0.5f) * 1.41421356f;
    float gain = 1.0f - amount * smoothstep(radius, 1.0f, d);
    return saturate(linear_to_srgb(srgb_to_linear(c) * gain));
}
