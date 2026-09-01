#include <metal_stdlib>
using namespace metal;

// Inspired by Rare UI's Fluid Orb, adapted for Metal and Douvo's compact overlay.
// https://www.rareui.com/components/fluidorb

struct DouvoGPTUniforms {
    float2 resolution;
    float time;
    float activity;
    float isActive;
    float padding;
};

struct DouvoGPTVertexOut {
    float4 position [[position]];
};

vertex DouvoGPTVertexOut douvoGPTFullscreenVertex(uint vertexID [[vertex_id]]) {
    DouvoGPTVertexOut out;
    float2 position = vertexID == 0 ? float2(-1.0, -1.0)
        : vertexID == 1 ? float2(3.0, -1.0)
        : float2(-1.0, 3.0);
    out.position = float4(position, 0.0, 1.0);
    return out;
}

float douvoGPTHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float douvoGPTNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(douvoGPTHash(i + float2(0.0, 0.0)), douvoGPTHash(i + float2(1.0, 0.0)), u.x),
        mix(douvoGPTHash(i + float2(0.0, 1.0)), douvoGPTHash(i + float2(1.0, 1.0)), u.x),
        u.y
    );
}

float douvoGPTFractalNoise(float2 p) {
    float value = 0.0;
    float amplitude = 0.6;
    for (int octave = 0; octave < 3; octave++) {
        value += amplitude * douvoGPTNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

fragment float4 douvoGPTOrbFragment(
    DouvoGPTVertexOut in [[stage_in]],
    constant DouvoGPTUniforms &uniforms [[buffer(0)]]
) {
    float2 resolution = max(uniforms.resolution, float2(1.0));
    float2 fragCoord = float2(in.position.x, resolution.y - in.position.y);

    // Fill the whole capsule. The SwiftUI host clips this rectangle to the overlay shape.
    float2 uv = fragCoord / resolution;

    float energy = mix(0.25, 1.0, clamp(uniforms.activity, 0.0, 1.0));
    energy = mix(energy, max(energy, 0.42), uniforms.isActive);
    float time = uniforms.time * (0.22 + 0.08 * energy);

    float2 drift = float2(
        sin(time) + 0.6 * sin(time * 1.7 + 1.3),
        cos(time * 0.8) + 0.6 * cos(time * 1.3 + 2.1)
    );

    float2 p = float2(uv.x * 1.8, uv.y) + drift * (0.60 + 0.14 * energy);
    float2 q = float2(
        douvoGPTFractalNoise(p + drift),
        douvoGPTFractalNoise(p + float2(3.2, 1.5) - drift)
    );
    float fluid = douvoGPTFractalNoise(p + 1.2 * q);

    // The white-to-color vertical body is what gives the reference its GPT voice-orb silhouette.
    float gradient = clamp(1.0 - uv.y, 0.0, 1.0);
    float anchor = smoothstep(0.0, 0.3, uv.y);
    float shade = clamp(gradient + (fluid - 0.5) * (0.80 + 0.10 * energy) * anchor, 0.0, 1.0);

    float3 white = float3(0.99, 1.0, 1.0);
    float3 gptBlue = float3(0.10, 0.45, 0.95);
    float3 lightBlue = mix(white, gptBlue, 0.50);

    float3 color = white;
    color = mix(color, lightBlue, smoothstep(0.28, 0.52, shade));
    color = mix(color, gptBlue, smoothstep(0.58, 0.88, shade));

    float alpha = 0.78 + 0.16 * energy;
    return float4(color * alpha, alpha);
}
