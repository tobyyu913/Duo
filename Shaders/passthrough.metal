#include <metal_stdlib>
using namespace metal;
struct Uniforms { float progress; float tilt; float defocus; float coverage; float2 size; float perspective; float blur; float shadow; float referenceAngle; float time; uint effect; };
struct Varying { float4 position [[position]]; float2 uv; };
vertex Varying duoVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    Varying v; v.position = float4(p[id],0,1); v.uv = float2((p[id].x+1)*0.5f, 1-(p[id].y+1)*0.5f); return v;
}
fragment float4 duoFragment(Varying v [[stage_in]], texture2d<float> desktop [[texture(0)]], constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float lod = u.defocus * 5.0f;   // crude test: blur via mip level only
    return float4(desktop.sample(s, v.uv, level(lod)).rgb * (1 - u.progress), 1);
}
