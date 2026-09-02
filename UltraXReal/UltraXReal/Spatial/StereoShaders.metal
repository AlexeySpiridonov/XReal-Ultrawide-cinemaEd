#include <metal_stdlib>
using namespace metal;

// Layouts mirror the Swift structs in StereoSceneRenderer.swift.
struct SceneVertex {
    float3 position;
    float3 normal;
    float4 color;
};

struct EyeUniforms {
    float4x4 viewProjection;
    float4x4 inverseViewProjection;
    float4 sunDir;      // xyz: direction towards the sun
    float4 cameraPos;   // xyz: eye position, w: time (s)
    float4 params;      // x: ground height (y), y: fog density
};

// MARK: - Noise

static float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

constant float3 kHorizon = float3(0.72, 0.84, 0.96);

static float3 applyFog(float3 color, float3 worldPos, constant EyeUniforms &eye) {
    float dist = length(worldPos - eye.cameraPos.xyz);
    float fog = 1.0 - exp(-dist * eye.params.y);
    return mix(color, kHorizon, fog);
}

// MARK: - Sky (fullscreen triangle, drawn first without depth)

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyOut skyVertex(uint vertexID [[vertex_id]]) {
    float2 ndc[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    SkyOut out;
    out.position = float4(ndc[vertexID], 1.0, 1.0);
    out.ndc = ndc[vertexID];
    return out;
}

fragment float4 skyFragment(SkyOut in [[stage_in]], constant EyeUniforms &eye [[buffer(2)]]) {
    float4 pn = eye.inverseViewProjection * float4(in.ndc, 0.0, 1.0);
    float4 pf = eye.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
    float3 dir = normalize(pf.xyz / pf.w - pn.xyz / pn.w);
    float3 sun = normalize(eye.sunDir.xyz);
    float time = eye.cameraPos.w;

    float y = dir.y;
    float3 zenith = float3(0.16, 0.40, 0.86);
    float3 col = mix(kHorizon, zenith, pow(clamp(y, 0.0, 1.0), 0.5));

    // Sun disc and glow
    float s = max(dot(dir, sun), 0.0);
    col += float3(1.0, 0.96, 0.86) * (pow(s, 1500.0) * 4.0 + pow(s, 8.0) * 0.10);

    // Clouds: project the view ray onto a cloud plane
    if (y > 0.0) {
        float2 uv = dir.xz / (y + 0.10) * 1.4 + float2(time * 0.006, time * 0.002);
        float c = fbm(uv);
        float cloud = smoothstep(0.50, 0.70, c);
        float fade = smoothstep(0.0, 0.20, y);
        float3 cloudCol = mix(float3(0.80, 0.83, 0.88), float3(1.0), smoothstep(0.55, 0.85, c));
        col = mix(col, cloudCol, cloud * 0.92 * fade);
    }

    // Distant hills just above the horizon
    float az = atan2(dir.x, -dir.z);
    float hills = 0.012 + 0.022 * fbm(float2(az * 2.2, 3.7)) + 0.010 * fbm(float2(az * 7.0, 9.1));
    if (y < hills) {
        float3 hillCol = mix(float3(0.30, 0.42, 0.28), kHorizon, 0.55);
        col = mix(hillCol, col, smoothstep(hills - 0.004, hills, y));
    }
    return float4(col, 1.0);
}

// MARK: - Scene geometry

struct SceneOut {
    float4 position [[position]];
    float3 worldPos;
    float3 worldNormal;
    float4 color;
};

vertex SceneOut sceneVertex(
    uint vertexID [[vertex_id]],
    const device SceneVertex *vertices [[buffer(0)]],
    constant float4x4 &model [[buffer(1)]],
    constant EyeUniforms &eye [[buffer(2)]]
) {
    SceneVertex v = vertices[vertexID];
    float4 world = model * float4(v.position, 1.0);
    SceneOut out;
    out.position = eye.viewProjection * world;
    out.worldPos = world.xyz;
    out.worldNormal = (model * float4(v.normal, 0.0)).xyz;
    out.color = v.color;
    return out;
}

fragment float4 groundFragment(SceneOut in [[stage_in]], constant EyeUniforms &eye [[buffer(2)]]) {
    float2 p = in.worldPos.xz;
    float r = length(p);

    float macro = fbm(p * 0.12);
    float meso = fbm(p * 1.1);
    float fine = vnoise(p * 26.0);
    float3 darkGreen = float3(0.12, 0.30, 0.07);
    float3 lightGreen = float3(0.42, 0.62, 0.17);
    float3 dry = float3(0.58, 0.56, 0.24);
    float3 col = mix(darkGreen, lightGreen, meso);
    col = mix(col, dry, smoothstep(0.55, 0.80, macro) * 0.55);
    col *= 0.82 + 0.34 * fine;

    // Trampled earth in the middle of the monument
    float3 earth = float3(0.46, 0.38, 0.24) * (0.8 + 0.4 * fine);
    col = mix(col, earth, smoothstep(4.0, 1.2, r) * 0.7);

    // Earth bank and ditch around the monument
    col *= 1.0 + 0.18 * exp(-pow((r - 50.0) / 3.0, 2.0));   // bank: lighter, drier
    col *= 1.0 - 0.22 * exp(-pow((r - 56.0) / 2.5, 2.0));   // ditch: shadowed

    float3 sun = normalize(eye.sunDir.xyz);
    col *= 0.38 + 0.72 * max(sun.y, 0.0);
    return float4(applyFog(col, in.worldPos, eye), 1.0);
}

fragment float4 stoneFragment(SceneOut in [[stage_in]], constant EyeUniforms &eye [[buffer(2)]]) {
    float3 n = normalize(in.worldNormal);
    float3 p = in.worldPos;
    float3 sun = normalize(eye.sunDir.xyz);

    float grain = fbm(p.xy * 2.6 + p.z * 1.9);
    float pits = vnoise(p.xz * 9.0 + p.y * 7.0);
    float3 base = in.color.rgb * (0.78 + 0.36 * grain) * (0.9 + 0.2 * pits);

    // Lichen on upper and shaded faces
    float lichen = smoothstep(0.60, 0.80, fbm(p.xz * 2.2 + p.y * 1.3)) * clamp(n.y * 0.7 + 0.5, 0.0, 1.0);
    base = mix(base, float3(0.58, 0.62, 0.30), lichen * 0.55);

    float diff = max(dot(n, sun), 0.0);
    float3 skyAmbient = mix(float3(0.22, 0.26, 0.18), float3(0.42, 0.52, 0.72), n.y * 0.5 + 0.5);
    float ao = mix(0.55, 1.0, smoothstep(0.0, 1.6, p.y - eye.params.x));
    float3 col = base * (skyAmbient * ao * 0.9 + float3(1.0, 0.95, 0.85) * diff * 1.05);
    return float4(applyFog(col, p, eye), 1.0);
}

fragment float4 shadowFragment(SceneOut in [[stage_in]], constant EyeUniforms &eye [[buffer(2)]]) {
    float dist = length(in.worldPos - eye.cameraPos.xyz);
    float strength = 0.55 * exp(-dist * eye.params.y);
    return float4(0.03, 0.06, 0.02, strength);
}
