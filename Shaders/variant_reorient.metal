// Duo for Mac — "reorient" variant.
//
// Physical reorientation. The desktop is a rectangle fixed in world space in the
// plane the lid rested in. A seated viewer's eye is posed in world coordinates
// (above and in front of the hinge, using the resting angle). As the lid tilts
// about the hinge (uv.y == 1) the DISPLAY rotates while the desktop stays put:
// every display pixel is inverse-mapped along the eye ray through it onto the
// resting plane, so from the viewer's seat the desktop appears locked in space
// and the glass slides across it. Defocus grows with the optical gap between the
// glass and the desktop plane (h·sin tilt), so the hinge row stays sharp; the
// exposed edges are blurred against black together with the content. Dimming
// follows the same gap; a faint vignette; a dissolve over the last 14% of progress.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float progress; float tilt; float defocus; float coverage;
    float2 size;
    float perspective; float blur; float shadow; float referenceAngle; float time; uint effect;
};
struct Varying { float4 position [[position]]; float2 uv; };

vertex Varying duoVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    Varying v;
    v.position = float4(p[id], 0, 1);
    v.uv = float2((p[id].x + 1) * 0.5f, 1 - (p[id].y + 1) * 0.5f);
    return v;
}

constant float kDeg = M_PI_F / 180.0f;

// Polynomial smooth minimum: exactly min() once |a-b| > k, rounded knee inside.
static inline float softMin(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / k, 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}

// One-sided rectangle coverage: fully opaque inside [0,1]², feathered only outward
// so border rows and columns are never darkened.
static inline float insideDesktop(float2 q, float2 fw) {
    float2 lo = smoothstep(-fw, float2(0.0f), q);
    float2 hi = 1.0f - smoothstep(float2(1.0f), 1.0f + fw, q);
    return lo.x * lo.y * hi.x * hi.y;
}

fragment float4 duoFragment(Varying v [[stage_in]],
                            texture2d<float> desktop [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 uv = v.uv;
    float p = clamp(u.progress, 0.0f, 1.0f);

    if (p <= 0.0f && u.tilt <= 0.0f && u.defocus <= 0.0f)
        return float4(desktop.sample(s, uv, level(0.0f)).rgb, 1.0f);     // exact passthrough
    if (p >= 1.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

    float persp = clamp(u.perspective, 0.0f, 1.0f);
    float soft  = clamp(u.blur, 0.0f, 1.0f);
    float shad  = clamp(u.shadow, 0.0f, 1.0f);
    float tilt  = clamp(u.tilt, 0.0f, 85.0f * kDeg);
    float focus = clamp(u.defocus, 0.0f, 1.0f);
    float aspect = max(u.size.x, 1.0f) / max(u.size.y, 1.0f);
    float texH = float(desktop.get_height());

    // ---------------------------------------------------------------- viewer
    // World frame at the hinge: y up, z toward the user. Eye in screen-heights.
    // The resting plane's direction from the hinge is (sin ref, cos ref) in (y,z);
    // its outward normal (toward the user) is (-cos ref, sin ref).
    float ref = clamp(u.referenceAngle, 90.0f, 140.0f) * kDeg;
    float eyeUp  = 2.2f;
    float eyeFwd = mix(3.6f, 2.6f, persp);
    float eN = clamp(-cos(ref) * eyeUp + sin(ref) * eyeFwd, 1.8f, 6.0f); // in front of the plane
    float eH = clamp( sin(ref) * eyeUp + cos(ref) * eyeFwd, -0.4f, 1.3f); // up the plane from the hinge

    // ------------------------------------------------------------- geometry
    // Angle the projection actually uses: whisper-quiet for the first degrees,
    // scaled by the perspective setting, and eased toward the angle at which the
    // glass would show less than qMin of the desktop's height (approaching edge-on).
    float onset = mix(0.22f, 1.0f, smoothstep(0.0f, 6.0f * kDeg, tilt));
    float tg = tilt * onset * mix(0.30f, 1.0f, persp);
    const float qMin = 0.25f;
    float R = length(float2(eN, qMin - eH));
    float phi = atan2(qMin - eH, eN);
    float tLimit = phi + acos(clamp(qMin * eN / R, -1.0f, 1.0f));
    tg = softMin(tg, max(tLimit, 20.0f * kDeg), 10.0f * kDeg);

    float h = 1.0f - uv.y;                    // height above the hinge (0 = hinge)
    float x = (uv.x - 0.5f) * aspect;
    float st = sin(tg), ct = cos(tg);
    // Display point in the resting-plane frame: (along, out) = (h·cos, h·sin).
    // Eye ray through it meets the plane (out = 0) at parameter tRay ≥ 1.
    float tRay = eN / max(eN - h * st, 0.25f);
    float qh = eH + tRay * (h * ct - eH);     // desktop height the pixel looks at
    float qx = tRay * x;
    float2 src = float2(qx / aspect + 0.5f, 1.0f - qh);

    // -------------------------------------------------------------- defocus
    // Optical gap between glass and desktop, in screen heights; the hinge has none.
    float gap = h * st;
    float gapNorm = gap / max(st, 1e-4f);     // == h: spatial profile independent of angle
    // Spatial profile: the hinge stays the most focused, but as the glass swings
    // toward edge-on the whole sheet softens so stretched rows never turn to bars.
    float closure = 1.0f - ct;                // 0 at rest → 0.83 at 80°
    float profile = 0.10f + 0.90f * pow(gapNorm, 1.25f) + 1.10f * closure;
    float sigmaUV = soft * focus * 0.040f * profile;   // blur radius ON THE GLASS, screen heights

    // Local Jacobian of the projection (source units per display unit) so the disc
    // stays round on the glass even where the desktop is stretched toward edge-on.
    float mX = tRay;
    float mY = max(tRay * ct + (h * ct - eH) * tRay * tRay * st / eN, 0.05f);
    float2 tapStep = float2(sigmaUV * mX / aspect, sigmaUV * mY);
    float sxPx = sigmaUV * mX * texH, syPx = sigmaUV * mY * texH;
    float lodBlur = max(log2(max(min(sxPx, syPx), 1e-3f)) - 0.35f,
                        log2(max(max(sxPx, syPx), 1e-3f)) - 1.3f);
    float lodMin  = 0.5f * log2(max(tRay, 1.0f));                 // horizontal minification
    float lod = clamp(max(lodBlur, lodMin), 0.0f, float(desktop.get_num_mip_levels() - 1));

    // Silhouette feather in source space: at least a pixel, and never narrower than
    // the tap spacing, otherwise the disc's taps quantise the edge into steps.
    float2 fw = max(max(fwidth(src), float2(1.0f / (texH * aspect), 1.0f / texH)), 0.8f * tapStep);

    // Three-ring disc, fixed offsets, gaussian-annulus weights. Every tap is masked
    // against the desktop rectangle so the silhouette blurs exactly like the content.
    float3 color = desktop.sample(s, src, level(lod)).rgb * insideDesktop(src, fw) * 0.30f;
    float wsum = 0.30f;
    const float radii[3]   = {0.75f, 1.50f, 2.25f};
    const float weights[3] = {0.56f, 0.49f, 0.18f};
    const float phase[3]   = {0.0f, M_PI_F / 6.0f, M_PI_F / 12.0f};
    for (uint ring = 0u; ring < 3u; ++ring) {
        for (uint i = 0u; i < 6u; ++i) {
            float a = float(i) * (M_PI_F / 3.0f) + phase[ring];
            float2 q = src + float2(cos(a), sin(a)) * radii[ring] * tapStep;
            color += desktop.sample(s, q, level(lod)).rgb * insideDesktop(q, fw) * weights[ring];
            wsum += weights[ring];
        }
    }
    color /= wsum;

    // -------------------------------------------------------------- shading
    // Depth shading follows the optical gap; the lid darkens further in its last third
    // so the final approach reads as almost shut before the dissolve takes over.
    float late = smoothstep(0.45f, 1.0f, p);
    float shade = 1.0f - shad * (0.36f * gap + 0.10f * p + 0.42f * late);
    float2 c = (uv - 0.5f) * float2(aspect, 1.0f);
    float r2v = dot(c, c) / (0.25f * (aspect * aspect + 1.0f));
    float vignette = 1.0f - (0.035f + 0.075f * shad) * smoothstep(0.0f, 0.6f, p) * r2v;
    float dissolve = 1.0f - smoothstep(0.86f, 1.0f, p);

    float3 out = color * shade * vignette * dissolve;

    if (u.coverage < 1.0f) {
        float3 plain = desktop.sample(s, uv, level(0.0f)).rgb;
        out = mix(plain, out, clamp(u.coverage, 0.0f, 1.0f));
    }
    return float4(out, 1.0f);
}
