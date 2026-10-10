#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Precomputed unit direction vectors for 16 outer radial directions
constant float2 kOuterDirs[16] = {
    float2( 1.00000f,  0.00000f), float2( 0.92388f,  0.38268f),
    float2( 0.70711f,  0.70711f), float2( 0.38268f,  0.92388f),
    float2( 0.00000f,  1.00000f), float2(-0.38268f,  0.92388f),
    float2(-0.70711f,  0.70711f), float2(-0.92388f,  0.38268f),
    float2(-1.00000f,  0.00000f), float2(-0.92388f, -0.38268f),
    float2(-0.70711f, -0.70711f), float2(-0.38268f, -0.92388f),
    float2( 0.00000f, -1.00000f), float2( 0.38268f, -0.92388f),
    float2( 0.70711f, -0.70711f), float2( 0.92388f, -0.38268f)
};

// Precomputed unit direction vectors for 8 inner radial directions
constant float2 kInnerDirs[8] = {
    float2( 1.00000f,  0.00000f), float2( 0.70711f,  0.70711f),
    float2( 0.00000f,  1.00000f), float2(-0.70711f,  0.70711f),
    float2(-1.00000f,  0.00000f), float2(-0.70711f, -0.70711f),
    float2( 0.00000f, -1.00000f), float2( 0.70711f, -0.70711f)
};

/// High-performance GPU text outline shader for subtitles.
/// Uses precomputed radial directions to eliminate runtime trigonometry on the GPU.
[[stitchable]] half4 subtitleOutline(
    float2 position,
    SwiftUI::Layer layer,
    float outlineRadius,
    half4 outlineColor
) {
    half4 current = layer.sample(position);
    if (outlineRadius <= 0.0) {
        return current;
    }

    // Sample 16 outer radial directions
    float maxNeighborAlpha = 0.0;
    for (int i = 0; i < 16; ++i) {
        float2 offset = kOuterDirs[i] * outlineRadius;
        half4 s = layer.sample(position + offset);
        maxNeighborAlpha = max(maxNeighborAlpha, float(s.a));
    }

    // Inner ring at 0.5 * radius for thickness continuity on thicker strokes
    if (outlineRadius > 1.5) {
        float innerRadius = outlineRadius * 0.5;
        for (int i = 0; i < 8; ++i) {
            float2 offset = kInnerDirs[i] * innerRadius;
            half4 s = layer.sample(position + offset);
            maxNeighborAlpha = max(maxNeighborAlpha, float(s.a));
        }
    }

    // outlineColor is passed premultiplied from SwiftUI (rgb already scaled by outlineColor.a).
    // Scale by maxNeighborAlpha for smooth antialiased outer stroke coverage.
    float strokeAlpha = maxNeighborAlpha * float(outlineColor.a);
    half4 premulOutline = half4(outlineColor.rgb * half(maxNeighborAlpha), half(strokeAlpha));

    // Standard Porter-Duff Over: foreground text composited over the outline
    half4 result = current + premulOutline * (1.0h - current.a);
    return result;
}
