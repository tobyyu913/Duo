// Duo for Mac — final "anchored glass" shader.
//
// CONSTRUCTION
// ------------
// The desktop is a plane fixed in the world. The display is a pane of glass
// hinged along its bottom edge (uv.y == 1) that rotates toward a viewer seated
// in front of the keyboard, a little above the top of the screen. For every
// output pixel we cast the viewer's ray through that pixel on the *tilted* pane
// and intersect it with the *resting* plane. The content therefore stays put
// behind the glass while the screen turns: the hinge row is pinned, the top of
// the pane comes forward and magnifies what lies behind it, and the sides expose
// a soft void where the desktop runs out (a keystone, never a flip).
//
// Geometry
//   * The tilt used for projection has a quadratic onset over the first ~4.5°
//     (1–4° is a pixel or two of drift, not a jolt), is scaled by the user's
//     perspective setting (0 ≈ no geometry at all), and is soft-limited at the
//     angle where the hinge row would be magnified 2.6x, so the vertical
//     stretch near closure is capped by a legibility constraint (the dock stays
//     a dock, never colour bars) at every perspective setting.
//
// Defocus ("comes into focus toward the hinge")
//   * Blur radius is defined ON THE GLASS (screen heights): a floor at the hinge,
//     growing as h^1.7 toward the top edge, plus a closure term in (1 - cos tilt)
//     so the whole sheet — including the dock — softens as the pane goes edge-on.
//   * The radius is carried into source space through the projection Jacobian
//     per axis, so the disc stays round on screen even where the desktop is
//     stretched. The mip level is chosen to carry most of the variance (box mips
//     of width 2^L under a bilinear tent have σ ≈ 0.5·2^L texels),
//     and a 19-tap Gaussian disc (1 + 6 + 12) covers only the RESIDUAL σ, so the
//     taps overlap and line-art wallpaper never shows ring/honeycomb echoes.
//     When the residual is sub-texel a single trilinear read is used.
//   * Every tap is masked against the desktop rectangle with a one-sided feather
//     no narrower than the tap spacing, so the side/top voids dissolve with the
//     same kernel as the content and border rows are never darkened. The hinge
//     edge is never masked: the desktop simply continues below it.
//
// Shading (all scalar — no hue shift anywhere)
//   * Far-edge darkening as the pane swings away from the light (shadow-scaled),
//     an always-present base dim so shadow = 0 still closes gracefully, a
//     steeper exposure fall-off in the second half, a faint centre-weighted
//     vignette, a broad neutral sheen high on the pane, and a dissolve to black
//     over the last 30% of progress. 60° reads ~half bright, 80° nearly shut.
//
// Contract: exact passthrough at progress/tilt/defocus == 0, opaque black at
// progress >= 1, alpha always 1, everything continuous, no time dependence.
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

constant float kDeg = M_PI_F / 180.0f;

// ---------------------------------------------------------------- helpers

// Quadratic-onset soft knee: ~x^2/(2k) for small x, ~x-k for large x.
static inline float softKnee(float x, float k) {
    return x - k * (1.0f - exp(-x / k));
}

// Polynomial smooth minimum: exactly min() once |a-b| > k, rounded knee inside.
static inline float softMin(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / k, 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}

// One-sided coverage of the desktop rectangle: 1 inside, feathered only
// outward (so border rows/columns keep full weight). The bottom edge is the
// hinge and is never masked — clamp_to_edge continues the desktop below it.
static inline float insideDesktop(float2 q, float2 fw) {
    float2 lo = smoothstep(-fw, float2(0.0f), q);
    float hiX = 1.0f - smoothstep(1.0f, 1.0f + fw.x, q.x);
    return lo.x * lo.y * hiX;
}

struct GlassMap {
    float2 src;   // desktop uv seen through this pane pixel
    float2 jac;   // |d src / d uv| per axis (source units per screen unit)
};

// Pane pixel at height h above the hinge (h = 1 - uv.y, in screen heights),
// tilted by theta toward the viewer. The viewer sits eyeD in front of the
// resting plane and eyeH up along it (eyeH > 1 keeps the top of the pane from
// ever looking above the desktop). Returns the point on the resting plane seen
// along the viewer's ray through the pane pixel, and the exact per-axis
// derivative of that mapping.
static GlassMap mapThroughGlass(float2 uv, float theta, float eyeD, float eyeH) {
    float h = 1.0f - uv.y;
    float s = sin(theta), c = cos(theta);
    float denom = max(eyeD - h * s, 1e-3f);
    float t = eyeD / denom;                        // ray scale (>= 1)
    float h0 = eyeH + t * (h * c - eyeH);          // height on the resting plane
    float x0 = t * (uv.x - 0.5f);
    float dh0 = max(t * (c * eyeD - s * eyeH) / denom, 0.02f);   // d h0 / d h
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
    float tilt = clamp(u.tilt, 0.0f, 85.0f * kDeg);
    float defocus = clamp(u.defocus, 0.0f, 1.0f);

    // Exact passthrough when open; opaque black when shut. (In the app the
    // drawable matches the texture, so an implicit-LOD sample at the pixel
    // centre is the original texel; the offline harness renders scaled.)
    if (p <= 0.0f && tilt <= 0.0f && defocus <= 0.0f) {
        return float4(desktop.sample(lin, v.uv).rgb, 1.0f);
    }
    if (p >= 1.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

    float persp = clamp(u.perspective, 0.0f, 1.0f);
    float soft  = clamp(u.blur, 0.0f, 1.0f);
    float shade = clamp(u.shadow, 0.0f, 1.0f);

    float2 texSize = float2(desktop.get_width(), desktop.get_height());
    float2 size = max(u.size, float2(1.0f));
    float aspect = size.x / size.y;
    float maxLod = float(desktop.get_num_mip_levels() - 1);
    float h = 1.0f - v.uv.y;                       // height above the hinge

    // ---- geometry: stationary viewer, rotating pane ------------------------
    float eyeD = mix(4.5f, 2.0f, persp);           // closer eye = stronger perspective
    float eyeH = 1.1f;
    float thetaG = softKnee(tilt, 4.5f * kDeg) * mix(0.06f, 1.0f, persp);
    // Legibility cap: the hinge row is magnified by 1 / (cos θ - (eyeH/eyeD) sin θ);
    // stop (softly) at the angle where that reaches kMaxStretch, so the dock
    // never turns into vertical colour bars however far the lid goes.
    {
        const float kMaxStretch = 2.6f;
        float r = eyeH / eyeD;
        float thetaCap = acos(clamp(rsqrt(1.0f + r * r) / kMaxStretch, -1.0f, 1.0f)) - atan(r);
        thetaG = softMin(thetaG, max(thetaCap, 20.0f * kDeg), 8.0f * kDeg);
    }
    GlassMap g = mapThroughGlass(v.uv, thetaG, eyeD, eyeH);

    // ---- defocus radius on the glass (screen heights) ----------------------
    float focus = pow(defocus, 1.15f);
    float closure = 1.0f - cos(tilt);              // raw lid rotation, 0 … 0.91
    // Hinge stays most in focus; the floor rises late in the fold and with
    // closure so the dock softens as the pane approaches edge-on.
    float floorBlur = mix(0.04f, 0.40f, smoothstep(0.35f, 0.86f, p));
    float profile = floorBlur + (1.0f - floorBlur) * pow(h, 1.7f)
                  + 0.7f * pow(closure, 2.5f);     // ~0 until 40°, 0.12 at 60°, 0.43 at 80°
    float sigmaScreen = mix(0.07f, 1.0f, soft) * 0.020f * focus * profile
                      + 0.0015f * closure;         // a hair of softness even at blur = 0

    // Into source space through the Jacobian, per axis (keeps the disc round on
    // screen), then into texels.
    float2 sigmaSrcUV = sigmaScreen * float2(g.jac.x / aspect, g.jac.y);
    float2 sigmaTex = sigmaSrcUV * texSize;
    float sMin = min(sigmaTex.x, sigmaTex.y), sMax = max(sigmaTex.x, sigmaTex.y);

    // ---- mip level: carry most of the variance in the mip chain ------------
    // Footprint of one output pixel in source texels (minification) …
    float2 footprint = g.jac * texSize / size;
    float baseLod = log2(max(max(footprint.x, footprint.y), 1.0f));
    // … and the blur: aim the box width at ~1.3x the geometric-mean sigma, but
    // never let the mip's own sigma exceed the smaller axis by more than ~10%.
    // (A bilinear read at level L is a box of 2^L texels under a tent of the
    // same width: sigma ≈ 0.5 * 2^L.)
    float boxW = clamp(1.3f * sqrt(sMin * sMax), 1.0f, max(2.2f * sMin, 1.0f));
    float lod = clamp(max(baseLod, log2(boxW)), 0.0f, maxLod);
    float mipSigma = 0.5f * exp2(lod);
    float2 tapSigmaTex = sqrt(max(sigmaTex * sigmaTex - mipSigma * mipSigma, 0.0f));
    float2 tapSigmaUV = tapSigmaTex / texSize;

    // Silhouette feather in source space: at least a texel, at least the
    // screen-pixel footprint, and never narrower than the tap spacing.
    float2 fw = max(max(fwidth(g.src), 1.0f / texSize), 0.9f * tapSigmaUV);

    // ---- gather ----------------------------------------------------------------
    float3 color;
    float cover;                                   // weighted desktop coverage (gates the sheen)
    if (max(tapSigmaTex.x, tapSigmaTex.y) < 0.35f) {
        cover = insideDesktop(g.src, fw);
        color = desktop.sample(lin, g.src, level(lod)).rgb * cover;
    } else {
        // 19-tap Gaussian disc: centre + 6 at 1.0 sigma + 12 at 1.9 sigma.
        const float w1 = 0.6065f, w2 = 0.1645f;
        const float r1 = 1.0f, r2 = 1.9f;
        cover = insideDesktop(g.src, fw);
        color = desktop.sample(lin, g.src, level(lod)).rgb * cover;
        float wsum = 1.0f;
        for (int i = 0; i < 6; ++i) {
            float a = float(i) * (M_PI_F / 3.0f);
            float2 q = g.src + float2(cos(a), sin(a)) * r1 * tapSigmaUV;
            float m = insideDesktop(q, fw) * w1;
            color += desktop.sample(lin, q, level(lod)).rgb * m;
            cover += m; wsum += w1;
        }
        for (int i = 0; i < 12; ++i) {
            float a = float(i) * (M_PI_F / 6.0f) + (M_PI_F / 12.0f);
            float2 q = g.src + float2(cos(a), sin(a)) * r2 * tapSigmaUV;
            float m = insideDesktop(q, fw) * w2;
            color += desktop.sample(lin, q, level(lod)).rgb * m;
            cover += m; wsum += w2;
        }
        color /= wsum; cover /= wsum;
    }

    // ---- shading (scalar only) --------------------------------------------------
    float swing = 1.0f - cos(thetaG);
    float shadeMix = mix(0.30f, 1.0f, shade);
    // Far edge darkens as it swings away from the light.
    float farDim = 1.0f - shadeMix * (0.10f + 0.90f * pow(h, 1.4f)) * min(swing * 1.6f, 0.75f);
    // Always-present base dim + user-scaled exposure fall-off in the second half.
    float baseDim = 1.0f - 0.35f * pow(p, 1.5f);
    float exposure = 1.0f - mix(0.42f, 0.68f, shade) * smoothstep(0.18f, 0.78f, p);
    // Faint centre-weighted vignette for a touch of through-glass depth.
    float2 cv = (v.uv - 0.5f) * float2(aspect, 1.0f);
    float r2v = dot(cv, cv) / (0.25f * (aspect * aspect + 1.0f));
    float vignette = 1.0f - (0.035f + 0.075f * shade) * smoothstep(0.0f, 0.6f, p) * r2v;

    // Neutral glass sheen: a broad diagonal band high on the pane, like a window
    // reflected in the glass. Screen-blend toward white — lifts darks, no hue.
    float band = smoothstep(0.15f, 0.9f, h);
    float diag = (v.uv.x * 0.55f + h) - 0.95f;
    float across = exp(-diag * diag / 0.22f);
    float sheen = 0.16f * mix(0.35f, 1.0f, shade) * band * across * min(swing * 2.5f, 1.0f);

    float dissolve = 1.0f - smoothstep(0.70f, 1.0f, p);

    color *= farDim;
    color = mix(color, float3(1.0f), sheen * cover);
    color *= baseDim * exposure * vignette * dissolve;

    // Final clear: blend against the untouched desktop.
    float cov = clamp(u.coverage, 0.0f, 1.0f);
    if (cov < 1.0f) {
        float3 plain = desktop.sample(lin, v.uv).rgb;
        color = mix(plain, color, cov);
    }
    return float4(color, 1.0f);
}
