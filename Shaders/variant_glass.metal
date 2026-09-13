// Duo for Mac — "anchored glass" variant.
//
// The desktop is a plane fixed in the world. The display is a pane of glass
// hinged at the bottom edge, rotating toward a viewer who sits in front of the
// keyboard, a little above the top of the screen. For every output pixel we
// cast the viewer's ray through that pixel on the *tilted* pane and intersect
// it with the *resting* plane, so the content appears to stay put behind the
// glass while the screen tilts: the hinge row is pinned, the top of the pane
// comes forward and magnifies what is behind it, and the sides expose a
// feathered void where the desktop runs out.
//
// On top of the geometry: a lens-like defocus (19-tap Gaussian disc at a
// matched mip level) growing with height above the hinge, dimming toward the
// far edge, a faint neutral glass sheen, and a dissolve to black over the last
// 14% of progress.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float progress;
    float tilt;
    float defocus;
    float coverage;
    float2 size;
    float perspective;
    float blur;
    float shadow;
    float referenceAngle;
    float time;
    uint  effect;
};

struct Varying { float4 position [[position]]; float2 uv; };

vertex Varying duoVertex(uint id [[vertex_id]]) {
    const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
    Varying v;
    v.position = float4(p[id], 0, 1);
    v.uv = float2((p[id].x + 1) * 0.5f, 1 - (p[id].y + 1) * 0.5f);
    return v;
}

// ---------------------------------------------------------------- helpers

// Quadratic-onset soft knee: ~x^2/(2k) for small x, ~x-k for large x.
static inline float softKnee(float x, float k) {
    return x - k * (1.0f - exp(-x / k));
}

// Smooth saturating minimum: returns ~x for x << a, approaches a for x >> a.
static inline float softLimit(float x, float a) {
    float r = x / a;
    float r2 = r * r;
    return x * rsqrt(sqrt(1.0f + r2 * r2));
}

struct GlassMap {
    float2 src;   // desktop uv seen through this pane pixel
    float2 jac;   // |d src / d uv| per axis (source units per screen unit)
};

// Pane pixel at height h above the hinge (h = 1 - uv.y, screen heights), tilted
// by theta toward the viewer. Viewer sits eyeD in front of the resting plane
// and eyeH up along it. Returns the point on the resting plane seen along the
// viewer's ray through the pane pixel.
static GlassMap mapThroughGlass(float2 uv, float theta, float eyeD, float eyeH) {
    float h = 1.0f - uv.y;
    float s = sin(theta), c = cos(theta);
    float denom = max(eyeD - h * s, 1e-3f);
    float t = eyeD / denom;                       // ray scale (>= 1)
    float h0 = eyeH + t * (h * c - eyeH);         // height on the resting plane
    float x0 = t * (uv.x - 0.5f);
    // d h0 / d h  =  t * (c*eyeD - s*eyeH) / denom   (positive while the pane
    // has not swung through the eye; softLimit on theta guarantees that).
    float dh0 = max(t * (c * eyeD - s * eyeH) / denom, 0.02f);
    GlassMap m;
    m.src = float2(0.5f + x0, 1.0f - h0);
    m.jac = float2(t, dh0);
    return m;
}

// ---------------------------------------------------------------- fragment

fragment float4 duoFragment(Varying v [[stage_in]],
                            texture2d<float> desktop [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler lin(coord::normalized, address::clamp_to_edge,
                          filter::linear, mip_filter::linear);

    float p = clamp(u.progress, 0.0f, 1.0f);
    float tilt = clamp(u.tilt, 0.0f, 85.0f * M_PI_F / 180.0f);
    float defocus = clamp(u.defocus, 0.0f, 1.0f);

    // Exact passthrough when open. (In the app drawable == texture size, so a
    // derivative-LOD sample at the pixel centre is the original texel.)
    if (p <= 0.0f && tilt <= 0.0f && defocus <= 0.0f) {
        return float4(desktop.sample(lin, v.uv).rgb, 1.0f);
    }
    if (p >= 1.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

    float persp  = clamp(u.perspective, 0.0f, 1.0f);
    float soft   = clamp(u.blur, 0.0f, 1.0f);
    float shade  = clamp(u.shadow, 0.0f, 1.0f);

    float2 texSize = float2(desktop.get_width(), desktop.get_height());
    float2 size = max(u.size, float2(1.0f));
    float aspect = size.x / size.y;
    float maxLod = float(desktop.get_num_mip_levels() - 1);

    // ---- geometry: stationary viewer, rotating pane ------------------------
    // Viewer distance shrinks with the perspective setting (stronger
    // magnification); eye height is a little above the top of the screen, so
    // the pane never runs past the top of the desktop, only past its sides.
    float eyeD = mix(4.5f, 2.0f, persp);
    float eyeH = 1.1f;
    // Tilt used for geometry: quadratic onset over the first ~3 degrees (so
    // 1-2 degrees is a pixel of drift, not a jolt), scaled by the perspective
    // setting, and soft-limited well short of the angle at which the pane
    // would swing through the viewer's eye.
    float kneeDeg = 3.0f;
    float thetaG = softKnee(tilt, kneeDeg * M_PI_F / 180.0f) * mix(0.45f, 1.0f, persp);
    float thetaTangent = atan(eyeD / eyeH);
    thetaG = softLimit(thetaG, 0.86f * thetaTangent);

    GlassMap g = mapThroughGlass(v.uv, thetaG, eyeD, eyeH);
    float h = 1.0f - v.uv.y;

    // ---- defocus: lens blur growing from the hinge -------------------------
    // sigma as a fraction of screen height, in screen space.
    float focus = pow(defocus, 1.15f);
    // Hinge stays most in focus, but the focus floor rises late in the fold so
    // the dock does not sit pin-sharp under a dissolving screen.
    float floorBlur = mix(0.05f, 0.45f, smoothstep(0.35f, 0.86f, p));
    float profile = floorBlur + (1.0f - floorBlur) * pow(h, 1.7f);
    float sigmaScreen = mix(0.10f, 1.0f, soft) * 0.022f * focus * profile;
    // Convert to source uv per axis through the Jacobian (screen height units ->
    // screen uv -> source uv).
    float2 sigmaSrcUV = sigmaScreen * float2(g.jac.x / aspect, g.jac.y);
    float2 sigmaTex = sigmaSrcUV * texSize;
    // Minification footprint of one output pixel in source texels.
    float2 footprint = g.jac * texSize / size;
    float baseLod = log2(max(max(footprint.x, footprint.y), 1.0f));
    float blurLod = log2(max(min(sigmaTex.x, sigmaTex.y) * 0.75f, 1.0f));
    float lod = clamp(max(baseLod, blurLod), 0.0f, maxLod);

    // 19-tap Gaussian disc: centre + 6 at 1.0 sigma + 12 at 1.9 sigma.
    float3 color = desktop.sample(lin, g.src, level(lod)).rgb;
    float wsum = 1.0f;
    {
        const float w1 = 0.6065f, w2 = 0.1645f;
        const float r1 = 1.0f, r2 = 1.9f;
        for (int i = 0; i < 6; ++i) {
            float a = float(i) * (M_PI_F / 3.0f);
            float2 o = float2(cos(a), sin(a)) * r1 * sigmaSrcUV;
            color += desktop.sample(lin, g.src + o, level(lod)).rgb * w1;
            wsum += w1;
        }
        for (int i = 0; i < 12; ++i) {
            float a = float(i) * (M_PI_F / 6.0f) + (M_PI_F / 12.0f);
            float2 o = float2(cos(a), sin(a)) * r2 * sigmaSrcUV;
            color += desktop.sample(lin, g.src + o, level(lod)).rgb * w2;
            wsum += w2;
        }
    }
    color /= wsum;

    // ---- feathered void where the desktop runs out --------------------------
    // Feather width follows the blur so the edge dissolves like the content
    // does; never thinner than ~1.5 texels. The bottom edge is the hinge and
    // never runs out (h0 >= 0), so only top and sides are feathered.
    float2 feather = max(1.6f * sigmaSrcUV, 1.5f / texSize);
    float2 inside = smoothstep(-feather, feather, g.src);
    float2 insideHi = 1.0f - smoothstep(1.0f - feather, 1.0f + feather, g.src);
    float border = inside.x * insideHi.x * inside.y;

    // ---- depth shading ------------------------------------------------------
    // The far edge of the pane darkens as it swings away from the light; the
    // whole image loses exposure in the second half of the fold.
    float swing = 1.0f - cos(thetaG);                       // 0 … ~0.6
    float shadeMix = mix(0.30f, 1.0f, shade);
    float farDim = 1.0f - shadeMix * (0.10f + 0.90f * pow(h, 1.4f)) * min(swing * 1.6f, 0.75f);
    float exposure = 1.0f - mix(0.50f, 0.75f, shade) * smoothstep(0.20f, 0.86f, p);

    // Faint neutral glass sheen high on the pane — a screen-blend toward white,
    // so dark pixels lift slightly and nothing changes hue.
    // A broad diagonal band, like a window reflected in the pane, brightest
    // toward the upper-left and fading before the hinge.
    float band = smoothstep(0.15f, 0.9f, h);
    float diag = (v.uv.x * 0.55f + h) - 0.95f;
    float across = exp(-diag * diag / 0.22f);
    float sheen = 0.085f * mix(0.35f, 1.0f, shade) * band * across * min(swing * 2.5f, 1.0f);

    float dissolve = 1.0f - smoothstep(0.86f, 1.0f, p);

    color = color * farDim * border;
    color = mix(color, float3(1.0f), sheen * border);
    color *= exposure * dissolve;

    // Final clear: blend against the untouched desktop.
    float cov = clamp(u.coverage, 0.0f, 1.0f);
    if (cov < 1.0f) {
        float3 plain = desktop.sample(lin, v.uv).rgb;
        color = mix(plain, color, cov);
    }
    return float4(color, 1.0f);
}
