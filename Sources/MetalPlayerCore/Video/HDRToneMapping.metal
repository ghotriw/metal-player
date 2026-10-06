#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoords;
};

vertex VertexOutput hdrVertexShader(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOutput out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoords = texCoords[vertexID];
    return out;
}

struct ToneMapUniforms {
    float targetNits;                    // 203.0
    float sourcePeakNits;                // 1000.0
    float outputExposure;                // 1.0
    float outputSaturation;              // 1.0
    float outputWarmCorrection;          // 0.0
    float outputHighlightCompression;    // 0.0
    float outputShadowDetail;            // 0.0
    float outputShadowLift;              // 0.0
    float outputSharpness;               // 0.0 to 1.0 (default 0.5 for CAS)
};

// PQ (SMPTE ST 2084) electro-optical transfer functions (EOTF / Inverse EOTF)
float3 pqToNits(float3 value) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float3 p = pow(max(value, 0.0), 1.0 / m2);
    float3 ratio = max(p - c1, 0.0) / max(c2 - c3 * p, 1e-6);
    return 10000.0 * pow(ratio, 1.0 / m1);
}

float nitsToPQ(float value) {
    constexpr float m1 = 2610.0 / 16384.0;
    constexpr float m2 = 2523.0 / 32.0;
    constexpr float c1 = 3424.0 / 4096.0;
    constexpr float c2 = 2413.0 / 128.0;
    constexpr float c3 = 2392.0 / 128.0;
    float powered = pow(clamp(value / 10000.0, 0.0, 1.0), m1);
    return pow((c1 + c2 * powered) / (1.0 + c3 * powered), m2);
}

// BT.2020 10-bit YUV -> Optical Nits
float3 nitsFromYUV(float y, float2 uv) {
    // 10-bit MSB normalized inputs
    float Y_norm  = (y - (4096.0 / 65535.0)) / (56064.0 / 65535.0);
    float Cb_norm = (uv.x - (32768.0 / 65535.0)) / (57344.0 / 65535.0);
    float Cr_norm = (uv.y - (32768.0 / 65535.0)) / (57344.0 / 65535.0);

    float3 nonlinear2020 = float3(
        Y_norm + 1.4746 * Cr_norm,
        Y_norm - 0.164553 * Cb_norm - 0.571353 * Cr_norm,
        Y_norm + 1.8814 * Cb_norm
    );
    return pqToNits(clamp(nonlinear2020, 0.0, 1.0));
}

// ITU-R BT.2390-8 EETF curve mapping
float3 mpvBT2390(float3 color, float sourcePeakNits, float sdrWhiteNits) {
    float sourcePeak = max(sourcePeakNits / sdrWhiteNits, 1.0);
    uint signalIndex = color.g > color.r ? 1 : 0;
    signalIndex = color.b > color[signalIndex] ? 2 : signalIndex;
    float3 signal = min(color, float3(sourcePeak));
    float originalSignal = max(signal[signalIndex], 1e-6);

    float4 signalPQ = float4(signal, sourcePeak) * (sdrWhiteNits / 10000.0);
    signalPQ = pow(max(signalPQ, 0.0), float4(2610.0 / 16384.0));
    signalPQ = (float4(3424.0 / 4096.0) + (2413.0 / 128.0) * signalPQ)
        / (1.0 + (2392.0 / 128.0) * signalPQ);
    signalPQ = pow(signalPQ, float4(2523.0 / 32.0));

    float sourceScale = 1.0 / max(signalPQ.a, 1e-6);
    signalPQ.rgb *= sourceScale;
    float targetPeakPQ = nitsToPQ(sdrWhiteNits) * sourceScale;
    float knee = 1.5 * targetPeakPQ - 0.5;

    float3 t = (signalPQ.rgb - knee) / max(1.0 - knee, 1e-6);
    float3 t2 = t * t;
    float3 t3 = t2 * t;
    float3 spline = (2.0 * t3 - 3.0 * t2 + 1.0) * knee
        + (t3 - 2.0 * t2 + t) * (1.0 - knee)
        + (-2.0 * t3 + 3.0 * t2) * targetPeakPQ;

    float3 mappedPQ = select(spline, signalPQ.rgb, signalPQ.rgb < knee);
    signal = pqToNits(mappedPQ * signalPQ.a) / sdrWhiteNits;

    float mappedMaximum = signal[signalIndex];
    float coefficient = max(mappedMaximum - 0.18, 1e-6) / max(mappedMaximum, 1.0);
    coefficient = 0.90 * pow(coefficient, 0.20);

    float sourceLumaNits = sdrWhiteNits * dot(color, float3(0.2627, 0.6780, 0.0593));
    float brightChromaProtection = max(
        smoothstep(0.35, 0.70, sourceLumaNits / sdrWhiteNits),
        smoothstep(260.0, 520.0, sourceLumaNits)
    );
    coefficient *= mix(1.0, 0.02, brightChromaProtection);

    float3 scaledColor = color * (mappedMaximum / originalSignal);
    return mix(scaledColor, signal, coefficient);
}

// BT.2020 Linear to Display P3 Linear (Column-major in Metal)
float3 bt2020_to_display_p3(float3 c) {
    float3x3 m = float3x3(
        float3( 1.343578, -0.065297,  0.002822), // Column 0
        float3(-0.282180,  1.075788, -0.019598), // Column 1
        float3(-0.061399, -0.010490,  1.016777)  // Column 2
    );
    return max(m * c, 0.0);
}

// Exposure compensation
float3 applyOutputExposure(float3 rgb, float exposure) {
    float3 mapped = max(rgb, 0.0) * max(exposure, 1.0);
    return mapped / (1.0 + (max(exposure, 1.0) - 1.0) * max(rgb, 0.0));
}

// Pure Gamma 2.2 transfer function (prevents sRGB piecewise black crush on calibrated displays)
float3 linearToSDRDisplay(float3 rgb) {
    return pow(max(rgb, 0.0), float3(1.0 / 2.2));
}

// Low-end luminance shadow lift with smooth roll-off protection
float3 applyShadowLift(float3 rgb, float amount) {
    float lift = clamp(amount, 0.0, 0.05);
    if (lift <= 0.0) {
        return rgb;
    }
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float blackProtection = smoothstep(0.002, 0.03, luma);
    float shadowWeight = 1.0 - smoothstep(0.14, 0.42, luma);
    float mappedLuma = luma + lift * blackProtection * shadowWeight;
    return rgb * (mappedLuma / max(luma, 1e-6));
}

// Helper to sample and tone map a single texture coordinate
float3 sampleAndToneMap(
    float2 coords,
    texture2d<float, access::sample> texY,
    texture2d<float, access::sample> texUV,
    sampler s,
    constant ToneMapUniforms &uniforms
) {
    float y = texY.sample(s, coords).r;
    float2 uv = texUV.sample(s, coords).rg;
    float3 sourceNits = nitsFromYUV(y, uv);
    float sdrWhite = max(uniforms.targetNits, 100.0);
    float3 sourceLinear = sourceNits / sdrWhite;
    float3 mapped2020 = mpvBT2390(sourceLinear, uniforms.sourcePeakNits, sdrWhite);
    float3 p3Linear = bt2020_to_display_p3(mapped2020);
    p3Linear = applyOutputExposure(p3Linear, uniforms.outputExposure);
    float3 displayGamma = linearToSDRDisplay(p3Linear);
    if (uniforms.outputShadowLift > 0.0) {
        displayGamma = applyShadowLift(displayGamma, uniforms.outputShadowLift);
    }
    return clamp(displayGamma, 0.0, 1.0);
}

fragment float4 hdrToneMapFragmentShader(
    VertexOutput in [[stage_in]],
    texture2d<float, access::sample> textureY [[texture(0)]],
    texture2d<float, access::sample> textureUV [[texture(1)]],
    constant ToneMapUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Compute reference tone-mapping pipeline exactly once for the center fragment
    float3 center = sampleAndToneMap(in.texCoords, textureY, textureUV, s, uniforms);

    // Contrast Adaptive Sharpening (FidelityFX CAS)
    float strength = clamp(uniforms.outputSharpness, 0.0, 1.0);
    if (strength <= 0.0) {
        return float4(center, 1.0);
    }

    float2 texelSize = float2(1.0 / float(textureY.get_width()), 1.0 / float(textureY.get_height()));

    // Sample neighbors from single-channel Y texture directly (avoiding 5x redundant BT.2390/PQ math)
    float y_c = textureY.sample(s, in.texCoords).r;
    float y_n = textureY.sample(s, in.texCoords + float2(0.0, -texelSize.y)).r;
    float y_s = textureY.sample(s, in.texCoords + float2(0.0,  texelSize.y)).r;
    float y_w = textureY.sample(s, in.texCoords + float2(-texelSize.x, 0.0)).r;
    float y_e = textureY.sample(s, in.texCoords + float2( texelSize.x, 0.0)).r;

    float y_min = min(y_c, min(min(y_n, y_s), min(y_w, y_e)));
    float y_max = max(y_c, max(max(y_n, y_s), max(y_w, y_e)));

    // Headroom prevents ringing/clipping artifacts near highlight peaks or black floor
    float headroom = min(y_min, 1.0 - y_max);
    float amplitude = sqrt(clamp(headroom / max(y_max, 1.0e-4), 0.0, 1.0));
    // FidelityFX CAS peak formulation: weight stays strictly in [-0.2, 0.0], ensuring (1 + 4*weight) >= 0.2
    float peak = -1.0 / mix(8.0, 5.0, strength);
    float weight = amplitude * peak;

    // High-frequency laplacian luma delta
    float laplacianY = (y_n + y_s + y_w + y_e) - 4.0 * y_c;
    // Scale delta back to display dynamic range and apply contrast enhancement to RGB
    float filterScale = weight / (1.0 + 4.0 * abs(weight));
    float3 sharpened = center + filterScale * laplacianY;

    return float4(clamp(sharpened, 0.0, 1.0), 1.0);
}
