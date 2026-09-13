// Duo for Mac — "expanding bloom" variant.
//
// The desktop is treated as a solid object anchored just behind the glass. As the lid
// tilts, the image swells around the hinge (bottom-centre anchored expansion), the
// upper content leaves through the top edge, and a depth-of-field blur grows with
// distance from the hinge. Softness is measured as a fraction of image height so the
// same source reads identically on the preview and on the Retina panel. A wide
// feathered mask (top wide, sides medium, bottom tight) and a hue-preserving scalar
// dimming carry the sense of the panel turning away; the last ~14% of progress
// dissolves to black.
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

// Smooth C1 ramp with a guard for zero width: a zero-width feather means "no feather".
static inline float ramp(float d, float w) {
    if (!(w > 0.0f)) return 1.0f;
    return smoothstep(0.0f, w, d);
}

// Depth-of-field sample: sigma is a fraction of image height. A single box-mip read
// at a level slightly below the sigma is combined with a fixed 12-tap disc so the
// result is a smooth, Gaussian-looking spread with no time-based randomness.
static float3 bloomSample(texture2d<float> desktop, sampler s, float2 uv, float sigmaUV, float aspect) {
    if (!(sigmaUV > 0.0f)) return desktop.sample(s, uv, level(0.0f)).rgb;
    float height = float(desktop.get_height());
    float sigmaPx = sigmaUV * height;
    // Each box-mip level contributes roughly 1/3 px^2 * 4^L of variance; choose a
    // level whose footprint is ~half the requested sigma, then fill in with taps.
    float lod = clamp(0.5f * log2(1.0f + sigmaPx * sigmaPx * 0.6f), 0.0f, float(desktop.get_num_mip_levels() - 1));
    // Remaining spread to cover with the tap disc (in uv, height units).
    float mipSigmaPx = 0.5f * exp2(lod);
    float tapSigmaPx = sqrt(max(sigmaPx * sigmaPx - mipSigmaPx * mipSigmaPx, 0.0f));
    float tapSigma = tapSigmaPx / height;
    if (tapSigma * height < 0.35f) return desktop.sample(s, uv, level(lod)).rgb;

    // Fixed 12-point disc (two rings of six), Gaussian-weighted. Offsets scale with
    // sigma; the x offsets are divided by the aspect so the disc is round on screen.
    const float2 disc[12] = {
        float2( 1.000f,  0.000f), float2( 0.500f,  0.866f), float2(-0.500f,  0.866f),
        float2(-1.000f,  0.000f), float2(-0.500f, -0.866f), float2( 0.500f, -0.866f),
        float2( 0.866f,  0.500f), float2( 0.000f,  1.000f), float2(-0.866f,  0.500f),
        float2(-0.866f, -0.500f), float2( 0.000f, -1.000f), float2( 0.866f, -0.500f)
    };
    float r1 = 0.85f * tapSigma, r2 = 1.75f * tapSigma;
    float w0 = 1.0f, w1 = exp(-0.5f * 0.85f * 0.85f), w2 = exp(-0.5f * 1.75f * 1.75f);
    float3 acc = desktop.sample(s, uv, level(lod)).rgb * w0;
    float wsum = w0;
    for (int i = 0; i < 6; i++) {
        float2 o = disc[i];
        float2 d1 = float2(o.x * r1 / aspect, o.y * r1);
        acc += desktop.sample(s, uv + d1, level(lod)).rgb * w1; wsum += w1;
    }
    for (int i = 6; i < 12; i++) {
        float2 o = disc[i];
        float2 d2 = float2(o.x * r2 / aspect, o.y * r2);
        acc += desktop.sample(s, uv + d2, level(lod)).rgb * w2; wsum += w2;
    }
    return acc / wsum;
}

fragment float4 duoFragment(Varying v [[stage_in]],
                            texture2d<float> desktop [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 screen = v.uv;
    float p = clamp(u.progress, 0.0f, 1.0f);
    float tilt = clamp(u.tilt, 0.0f, 85.0f * M_PI_F / 180.0f);
    float focus = clamp(u.defocus, 0.0f, 1.0f);
    float coverage = clamp(u.coverage, 0.0f, 1.0f);

    // Exact passthrough while the lid rests. Nothing below may pop away from this.
    if (p <= 0.0f && tilt <= 0.0f && focus <= 0.0f) {
        return float4(desktop.sample(s, screen, level(0.0f)).rgb, 1.0f);
    }
    if (p >= 1.0f) return float4(0.0f, 0.0f, 0.0f, 1.0f);

    float persp = clamp(u.perspective, 0.0f, 1.0f);
    float soft  = clamp(u.blur, 0.0f, 1.0f);
    float shade = clamp(u.shadow, 0.0f, 1.0f);
    float aspect = max(u.size.x, 1.0f) / max(u.size.y, 1.0f);
    float height = 1.0f - screen.y;                 // 0 at the hinge, 1 at the top edge

    // ---- Spatial: bottom-centre anchored swell -------------------------------------
    // The swell has two sources: overall progress (slow, eased over the whole span) and
    // the physical tilt (1 - cos is quadratic in the first degrees, so 1–4° drift by a
    // pixel or so, while 40–60° bloom generously). Perspective scales the whole thing.
    float lean = 1.0f - cos(tilt);
    float swell = p * (0.10f + 0.28f * persp) + lean * (0.06f + 0.30f * persp);
    // Expansion grows with height: the hinge stays put, the top blooms outward.
    float expand = 1.0f + swell * (0.35f + 0.65f * height);
    // Slight extra horizontal stretch toward the top (the top edge is nearer the eye).
    float stretchX = 1.0f + (0.04f + 0.10f * persp) * (p + 0.5f * lean) * height;
    float2 src;
    src.x = 0.5f + (screen.x - 0.5f) / (expand * stretchX);
    src.y = 1.0f - height / expand;

    // ---- Depth of field: strong far from the hinge, gentle near it -----------------
    float spread = 0.16f + 0.84f * pow(height, 1.5f);   // hinge soft, never pin-sharp
    float sigmaUV = soft * 0.034f * focus * spread;
    // Minification never happens (we magnify), but keep a hair of softness proportional
    // to tilt so even blur == 0 does not look like a hard zoom.
    sigmaUV += 0.0025f * lean;
    float3 color = bloomSample(desktop, s, src, sigmaUV, aspect);

    // ---- Wide feathered mask: top wide, sides medium, bottom tight -----------------
    float open = p + 0.6f * lean;                    // grows with both drivers, still ~0 at rest
    float late = smoothstep(0.45f, 1.0f, p);         // the frame closes in near the end
    float topW    = open * (0.10f + 0.16f * soft) + 1.5f * sigmaUV + 0.10f * late;
    // Sides taper: wider toward the top so the visible area reads as a receding pane.
    float sideW   = ((open * (0.05f + 0.09f * soft) + 1.5f * sigmaUV) * (0.70f + 0.50f * height) + 0.07f * late) / aspect;
    float bottomW = open * (0.012f + 0.020f * soft) + 0.5f * sigmaUV + 0.07f * late;
    float mask = ramp(screen.y, topW) * ramp(height, bottomW)
               * ramp(screen.x, sideW) * ramp(1.0f - screen.x, sideW);

    // ---- Hue-preserving dimming: scalar only, heavier toward the top ---------------
    // A base darkening that is always present (so shadow == 0 still closes gracefully),
    // plus the user's depth shading, heavier toward the top edge.
    float dim = 1.0f - 0.45f * pow(p, 1.5f);
    dim *= 1.0f - shade * (0.30f * p + 0.15f * lean) * (0.5f + 0.5f * height);

    // ---- Dissolve to black over the last ~14% of progress --------------------------
    float dissolve = 1.0f - smoothstep(0.86f, 1.0f, p);

    float3 result = color * mask * dim * dissolve;
    if (coverage < 1.0f) {
        float3 plain = desktop.sample(s, screen, level(0.0f)).rgb;
        result = mix(plain, result, coverage);
    }
    return float4(result, 1.0f);
}
