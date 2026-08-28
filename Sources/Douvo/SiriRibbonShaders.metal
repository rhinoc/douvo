// Adapted from Will Suo's Siri27SiriAnimation wave shader.
// Copyright (c) 2026 Will Suo. Licensed under the MIT License.

#include <metal_stdlib>
using namespace metal;

struct DouvoSiriUniforms {
    float2 resolution;
    float time;
    float activity;
    float isActive;
    float padding;
};

struct DouvoSiriVertexOut {
    float4 position [[position]];
};

vertex DouvoSiriVertexOut douvoSiriFullscreenVertex(uint vertexID [[vertex_id]]) {
    DouvoSiriVertexOut out;
    float2 position = vertexID == 0 ? float2(-1.0, -1.0)
        : vertexID == 1 ? float2(3.0, -1.0)
        : float2(-1.0, 3.0);
    out.position = float4(position, 0.0, 1.0);
    return out;
}

constant float DOUVO_PI = 3.14159265359;
constant float DOUVO_AMPLITUDE = 0.32;
constant float DOUVO_FREQ = 1.1;
constant float DOUVO_ABERR_FREQ = 1.0;
constant float DOUVO_SPEED = 2.4;
constant float DOUVO_WAVE_SCALE = 0.6;
constant float DOUVO_ABERRATION = 2.6;
constant float DOUVO_THICKNESS = 3.0;
constant float DOUVO_INTENSITY = 2.0;
constant float DOUVO_RESOLVED = 1.0;
constant float DOUVO_FALLOFF = 1.7;
constant float DOUVO_EDGE_ENVELOPE = 0.9;
constant float DOUVO_EDGE_MASK = 0.4;
constant float DOUVO_BAND_FILL = 30000.0;
constant float DOUVO_BAND_THICK = 0.08;
constant float DOUVO_SOFTNESS = 2.5;
constant float DOUVO_UNRES_SCALE = 0.14;
constant float DOUVO_MID_ABERRATION = 0.8;
constant float DOUVO_MID_ABERRATION_AMPLITUDE = 0.05;
constant float DOUVO_MID_SOFTNESS = 0.4;
constant float DOUVO_HIGH_ABERRATION = 0.5;
constant float DOUVO_HIGH_ABERRATION_AMPLITUDE = 0.06;
constant float DOUVO_LOW_AMPLITUDE = 6.0;
constant float DOUVO_LOW_INTENSITY = 1.5;

float3 douvoWaveSpectral4(int sample) {
    float x = float(sample);
    return clamp(
        float3(abs(x - 3.0) - 1.0, 2.0 - abs(x - 2.0), 2.0 - abs(x - 4.0)),
        float3(0.0),
        float3(1.0)
    );
}

float4 douvoWaveMain(
    float2 fragCoord,
    float2 resolution,
    float time,
    float activity,
    float isActive
) {
    float2 r = resolution.xy;
    float aspect = r.x / max(r.y, 1.0);
    float2 p = (fragCoord + 0.5) * 2.0 / r - 1.0;
    p.x *= aspect;
    float yScreen = p.y;
    p /= DOUVO_WAVE_SCALE;

    float resolved = clamp(DOUVO_RESOLVED, 0.0, 1.0);
    float energy = mix(0.18, 1.0, clamp(activity, 0.0, 1.0));
    energy = mix(energy, max(energy, 0.30), isActive);
    float low = (0.45 + 0.45 * sin(time * 0.8) * sin(time * 0.37 + 1.0))
        * mix(0.55, 1.0, energy);
    float mid = (0.40 + 0.40 * sin(time * 1.7 + 2.0) * sin(time * 0.53))
        * mix(0.45, 1.0, energy);
    float high = (0.30 + 0.30 * sin(time * 2.9 + 4.0) * sin(time * 0.71 + 2.0))
        * mix(0.35, 1.0, energy);

    float drift = fmod(time, 20.0 * DOUVO_PI) * DOUVO_SPEED;
    float xN = p.x / max(aspect, 1.0);
    float env = cos(DOUVO_PI * 0.5 * min(abs(DOUVO_EDGE_ENVELOPE * xN), 1.0));
    env *= env;
    float amplitude = DOUVO_AMPLITUDE * mix(0.72, 1.18, energy);
    float a1 = amplitude + 0.01 * low * DOUVO_LOW_AMPLITUDE;
    float a2 = a1
        + mid * DOUVO_MID_ABERRATION_AMPLITUDE
        + high * DOUVO_HIGH_ABERRATION_AMPLITUDE;
    float aberration = (DOUVO_ABERRATION
        + mid * DOUVO_MID_ABERRATION
        + high * DOUVO_HIGH_ABERRATION) * resolved;
    float thickness = mix(0.1, 0.01 * DOUVO_THICKNESS, resolved);
    float intensity = mix(
        0.1,
        0.01 * (DOUVO_INTENSITY + low * DOUVO_LOW_INTENSITY) * mix(0.55, 1.0, energy),
        resolved
    );
    float softness = 0.01 * resolved * max(0.0, DOUVO_SOFTNESS + mid * DOUVO_MID_SOFTNESS);
    float unresDistance = max(
        length(p) - mix(0.14, DOUVO_UNRES_SCALE, resolved),
        0.0
    );
    float yMain = a1 * env * resolved * sin(p.x * DOUVO_FREQ + drift);

    float3 numerator = float3(0.0);
    float3 denominator = float3(0.0);
    float bandFillThickness = max(DOUVO_BAND_THICK, 1e-4);
    float bandAmount = 1e-4 * DOUVO_BAND_FILL * intensity;
    for (int sample = 0; sample < 4; sample++) {
        float3 hue = mix(float3(1.0), douvoWaveSpectral4(sample), resolved);
        denominator += hue;
        float chroma = mix(-aberration, aberration, float(sample) / 3.0);
        float yLayer = a2 * env * resolved
            * sin(p.x * DOUVO_ABERR_FREQ + drift + chroma);
        float distance = mix(unresDistance, abs(p.y - yLayer), resolved);
        float lorentzian = mix(
            1.0 / (1.0 + (0.02 * distance) * (0.02 * distance)),
            1.0,
            resolved
        );
        float line = intensity / (
            sqrt(distance * distance + softness * softness) + thickness
        );
        float lowBand = min(yMain, yLayer);
        float highBand = max(yMain, yLayer);
        float bandDistance = max(0.0, max(p.y - highBand, lowBand - p.y));
        float band = bandAmount
            / (bandDistance + bandFillThickness);
        numerator += hue * lorentzian * (line + band);
    }

    float3 color = numerator / max(denominator, float3(0.001));
    float mainDistance = mix(unresDistance, abs(p.y - yMain), resolved);
    float mainLorentzian = mix(
        1.0 / (1.0 + (0.02 * mainDistance) * (0.02 * mainDistance)),
        1.0,
        resolved
    );
    float boost = (1.0 - resolved) * (14.0 * low + 4.0);
    color += 0.5 * intensity * (mainLorentzian + boost) / (
        sqrt(mainDistance * mainDistance + softness * softness) + thickness
    );
    color = pow(max(color, float3(0.0)), float3(1.5));

    float edgeT = clamp((abs(yScreen) - 1.0) / (-DOUVO_EDGE_MASK), 0.0, 1.0);
    float edge = edgeT * edgeT * (3.0 - 2.0 * edgeT);
    float gaussian = exp(-pow(xN * DOUVO_FALLOFF, 2.0));
    color *= mix(1.0, edge * gaussian, resolved);
    color *= resolved;

    color = min(color, float3(1.0));
    float brightness = max(max(color.r, color.g), color.b);
    float alpha = clamp(brightness, 0.0, 1.0);
    return float4(color, alpha);
}

fragment float4 douvoSiriWaveFragment(
    DouvoSiriVertexOut in [[stage_in]],
    constant DouvoSiriUniforms &uniforms [[buffer(0)]]
) {
    float2 fragCoord = float2(in.position.x, uniforms.resolution.y - in.position.y);
    return douvoWaveMain(
        fragCoord,
        uniforms.resolution,
        uniforms.time,
        uniforms.activity,
        uniforms.isActive
    );
}
