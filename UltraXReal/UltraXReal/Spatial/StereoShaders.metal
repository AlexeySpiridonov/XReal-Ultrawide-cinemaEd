#include <metal_stdlib>
using namespace metal;

// Layouts mirror the Swift structs in StereoSceneRenderer.swift.
struct SceneVertex {
    float3 position;
    float3 normal;
};

struct LineVertex {
    float3 position;
    float4 color;
};

struct InstanceData {
    float4x4 model;
    float4 color;
};

struct EyeUniforms {
    float4x4 viewProjection;
    float4 lightDir;
};

struct SceneVertexOut {
    float4 position [[position]];
    float3 worldNormal;
    float4 color;
};

vertex SceneVertexOut stereoSceneVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device SceneVertex *vertices [[buffer(0)]],
    const device InstanceData *instances [[buffer(1)]],
    constant EyeUniforms &eye [[buffer(2)]]
) {
    SceneVertex v = vertices[vertexID];
    InstanceData inst = instances[instanceID];

    float4 world = inst.model * float4(v.position, 1.0);

    SceneVertexOut out;
    out.position = eye.viewProjection * world;
    out.worldNormal = normalize((inst.model * float4(v.normal, 0.0)).xyz);
    out.color = inst.color;
    return out;
}

fragment float4 stereoSceneFragment(
    SceneVertexOut in [[stage_in]],
    constant EyeUniforms &eye [[buffer(2)]]
) {
    float diffuse = max(dot(normalize(in.worldNormal), normalize(eye.lightDir.xyz)), 0.0);
    float3 color = in.color.rgb * (0.3 + 0.7 * diffuse);
    return float4(color, 1.0);
}

vertex SceneVertexOut stereoLineVertex(
    uint vertexID [[vertex_id]],
    const device LineVertex *vertices [[buffer(0)]],
    constant EyeUniforms &eye [[buffer(2)]]
) {
    LineVertex v = vertices[vertexID];
    SceneVertexOut out;
    out.position = eye.viewProjection * float4(v.position, 1.0);
    out.worldNormal = float3(0, 1, 0);
    out.color = v.color;
    return out;
}

fragment float4 stereoLineFragment(SceneVertexOut in [[stage_in]]) {
    return in.color;
}

