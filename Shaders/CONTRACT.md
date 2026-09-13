# Duo shader contract

One Metal source file. Compiled at runtime with `device.makeLibrary(source:)`, so it must be
self-contained (`#include <metal_stdlib>` only).

```metal
struct Uniforms {
    float progress;        // 0 open → 1 fully folded (eased over the whole closing span)
    float tilt;            // radians the lid has rotated from its resting plane, 0…85°
    float defocus;         // 0…1 optical blur amount (gentle onset, saturates before closure)
    float coverage;        // 0…1 — blend factor vs the untouched desktop during the final clear
    float2 size;           // drawable size in pixels (offset 16)
    float perspective;     // user setting 0…1 (strength of the spatial/perspective illusion)
    float blur;            // user setting 0…1 (softness)
    float shadow;          // user setting 0…1 (dimming / depth shading)
    float referenceAngle;  // resting lid angle in degrees (typically 100–125)
    float time;            // seconds since the effect began (offline tests pass 0; must look right at 0)
    uint  effect;          // 0 = duo (reserved for variants)
};                          // 48 bytes total, float2 at offset 16

struct Varying { float4 position [[position]]; float2 uv; };   // uv: (0,0) top-left, (1,1) bottom-right

vertex Varying duoVertex(uint id [[vertex_id]]);   // full-screen triangle, 3 vertices, no buffers

fragment float4 duoFragment(Varying v [[stage_in]],
                            texture2d<float> desktop [[texture(0)]],   // BGRA, FULL mip chain present
                            constant Uniforms& u [[buffer(0)]]);
```

Rules the app relies on:
- `progress == 0` (and tilt == 0, defocus == 0) MUST return the desktop pixel exactly (passthrough).
- `progress >= 1` MUST return opaque black.
- Output alpha is always 1 (the overlay window is opaque black).
- The hinge is the BOTTOM edge of the screen (uv.y = 1). The lid rotates about it.
- Everything continuous in `progress`/`tilt`/`defocus` — no popping. No `time`-dependent
  randomness. Must look correct at time == 0.
- `desktop` has mipmaps (box-filtered). Use `sampler` with `mip_filter::linear` and `level(lod)`
  or `bias`; multi-tap at a chosen LOD gives smoother blur than a single trilinear read.
- Only sample `desktop` — no other textures, no buffers other than `Uniforms`.
- Must compile with no warnings-as-errors issues on macOS 15+ Metal.
