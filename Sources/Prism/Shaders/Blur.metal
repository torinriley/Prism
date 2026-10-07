// Blur.metal — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

#include "Common.h"

struct BlurParams { int radius; };

// Separable Gaussian: out(x) = sum_{i=-r..r} w[i + r] * in(clamp(x + i)).
// Edges clamp to the border texel. Operates on stored (premultiplied, encoded) values.
// `weights` holds 2r+1 normalized floats.

kernel void prism_blur_horizontal(texture2d<float, access::read>  src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant BlurParams &p [[buffer(0)]],
                                  constant float *weights [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int last = int(src.get_width()) - 1;
    float4 acc = 0.0f;
    for (int i = -p.radius; i <= p.radius; ++i) {
        acc += weights[i + p.radius] * src.read(uint2(clamp(int(gid.x) + i, 0, last), gid.y));
    }
    dst.write(acc, gid);
}

kernel void prism_blur_vertical(texture2d<float, access::read>  src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant BlurParams &p [[buffer(0)]],
                                constant float *weights [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int last = int(src.get_height()) - 1;
    float4 acc = 0.0f;
    for (int i = -p.radius; i <= p.radius; ++i) {
        acc += weights[i + p.radius] * src.read(uint2(gid.x, clamp(int(gid.y) + i, 0, last)));
    }
    dst.write(acc, gid);
}

// MARK: Threadgroup-tiled, register-blocked variants
//
// Same math as the kernels above, restructured for speed. Each threadgroup first loads the texels
// it needs (with a halo of `radius` each side along the blur axis) into threadgroup memory once.
// Each thread then produces FOUR adjacent outputs from a single sliding window over that tile:
// every tile element it reads feeds up to four accumulators, so tile reads per output fall ~4x.
//
// `weights` is padded with three zeros on each side (2r + 7 floats, tap i at index i + 3) so the
// four accumulators can use one unconditional loop: output j, window position k uses tap k - j.
// Layouts use the *nominal* threadgroup size so partial edge groups agree with the host's sizing.

constant int kOutputsPerThread = 4;

kernel void prism_blur_horizontal_tiled(texture2d<float, access::read>  src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]],
                                        constant BlurParams &p [[buffer(0)]],
                                        constant float *weights [[buffer(1)]],
                                        threadgroup float4 *tile [[threadgroup(0)]],
                                        uint2 gid [[thread_position_in_grid]],
                                        uint2 tid [[thread_position_in_threadgroup]],
                                        uint2 tgid [[threadgroup_position_in_grid]],
                                        uint2 nominal [[dispatch_threads_per_threadgroup]],
                                        uint2 actual [[threads_per_threadgroup]]) {
    const int r = p.radius;
    const int rowElements = int(nominal.x) * kOutputsPerThread + 2 * r;
    const int rowBase = int(tid.y) * rowElements;
    const int width = int(src.get_width());
    const int x0 = int(tgid.x * nominal.x) * kOutputsPerThread - r;
    for (int c = int(tid.x); c < rowElements; c += int(actual.x)) {
        tile[rowBase + c] = src.read(uint2(clamp(x0 + c, 0, width - 1), gid.y));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float4 a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
    const int base = rowBase + int(tid.x) * kOutputsPerThread;
    for (int k = 0; k < 2 * r + 4; ++k) {
        float4 v = tile[base + k];
        a0 += weights[k + 3] * v;
        a1 += weights[k + 2] * v;
        a2 += weights[k + 1] * v;
        a3 += weights[k]     * v;
    }
    const uint x = gid.x * kOutputsPerThread;
    if (x     < uint(width)) dst.write(a0, uint2(x,     gid.y));
    if (x + 1 < uint(width)) dst.write(a1, uint2(x + 1, gid.y));
    if (x + 2 < uint(width)) dst.write(a2, uint2(x + 2, gid.y));
    if (x + 3 < uint(width)) dst.write(a3, uint2(x + 3, gid.y));
}

kernel void prism_blur_vertical_tiled(texture2d<float, access::read>  src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant BlurParams &p [[buffer(0)]],
                                      constant float *weights [[buffer(1)]],
                                      threadgroup float4 *tile [[threadgroup(0)]],
                                      uint2 gid [[thread_position_in_grid]],
                                      uint2 tid [[thread_position_in_threadgroup]],
                                      uint2 tgid [[threadgroup_position_in_grid]],
                                      uint2 nominal [[dispatch_threads_per_threadgroup]],
                                      uint2 actual [[threads_per_threadgroup]]) {
    const int r = p.radius;
    const int tileRows = int(nominal.y) * kOutputsPerThread + 2 * r;
    const int height = int(src.get_height());
    const int y0 = int(tgid.y * nominal.y) * kOutputsPerThread - r;
    for (int row = int(tid.y); row < tileRows; row += int(actual.y)) {
        tile[row * int(nominal.x) + int(tid.x)] = src.read(uint2(gid.x, clamp(y0 + row, 0, height - 1)));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float4 a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
    const int base = int(tid.y) * kOutputsPerThread;
    for (int k = 0; k < 2 * r + 4; ++k) {
        float4 v = tile[(base + k) * int(nominal.x) + int(tid.x)];
        a0 += weights[k + 3] * v;
        a1 += weights[k + 2] * v;
        a2 += weights[k + 1] * v;
        a3 += weights[k]     * v;
    }
    const uint y = gid.y * kOutputsPerThread;
    if (y     < uint(height)) dst.write(a0, uint2(gid.x, y));
    if (y + 1 < uint(height)) dst.write(a1, uint2(gid.x, y + 1));
    if (y + 2 < uint(height)) dst.write(a2, uint2(gid.x, y + 2));
    if (y + 3 < uint(height)) dst.write(a3, uint2(gid.x, y + 3));
}
