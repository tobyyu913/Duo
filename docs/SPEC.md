# Duo for Mac — app specification

Recreates the iPhone Duo fold animation on a MacBook: as the lid closes, the desktop appears
to stay locked in space while the screen physically reorients around it, blurring and stretching
"like peering through a pane of glass"; as the lid opens, content comes back into focus.

Project: `/Users/toby/Codes/Duo` — SwiftPM executable, macOS 15+, Swift 5.9 tools, NO third-party
dependencies. App name `Duo`, executable `Duo`, bundle id `com.toby.duo`, menu-bar only (LSUIElement).

## Verified facts about this machine (do not re-derive)
- 16" MacBook Pro M4 Max (Mac16,5), macOS 27.0, Xcode 26.6, Apple Silicon only.
- Built-in display is 4112×2658 px (2056×1329 pt @2x), 120 Hz ProMotion.
- Lid angle sensor: IOHIDDevice, VendorID 0x05AC, usage page 0x20, usage 0x8A, product "las",
  Built-In = true (an external display can expose the same usage and must be skipped via
  kIOHIDBuiltInKey). Open with IOHIDManager + IOHIDDeviceOpen (no permission, no entitlement).
  Feature report 7: 5 bytes `[0x07, b0, b1, b2, b3]` little-endian hundredths of a degree
  (verified: `[7,218,48,0,0]` → 125.06°). Fallback feature report 1: 3 bytes `[0x01, lo, hi]`
  whole degrees. Read with `IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, buf, &len)`.
  0 = closed, ~125° = normal open. Reads succeed at any rate; poll on a background queue.
  At rest the value JITTERS by ~0.1–0.2° (14 distinct values in 1.5 s) — the model must have a
  deadband so a resting lid never triggers the effect.
- Codesigning identity available: `Apple Development: yutan@me.com (V2R79MY3H2)`. Sign with it so
  the Screen Recording (TCC) grant survives rebuilds; fall back to ad-hoc `-` if absent.
- Existing conventions (mirror `/Users/toby/Codes/ClipStack/build_app.sh`): `build_app.sh` builds
  release, assembles `Duo.app` next to the sources with a generated icon, writes Info.plist,
  codesigns, installs to `/Applications/Duo.app`; supports `--no-install` and `--watch`.

## Fixed pieces — DO NOT MODIFY
- `Sources/Duo/FoldState.swift` — `FoldState.at(angle:reference:)` (angle → progress/defocus/tilt)
  and `DuoUniforms` (48-byte layout mirrored by the shader). Other code uses them as-is.
- `Shaders/CONTRACT.md` — the Metal interface. The final shader is `Shaders/duo.metal`, written by
  a separate design track; until it exists use `Shaders/passthrough.metal` as a stand-in.
- `Tools/duo-render/` + `Tools/build_render.sh` — offline harness; leave alone.

## Shader embedding
`build_app.sh` (and a `Tools/gen_shader.sh` it calls) must regenerate
`Sources/Duo/ShaderSource.swift` from `Shaders/duo.metal` as a raw string:
```
// GENERATED from Shaders/duo.metal by Tools/gen_shader.sh — do not edit.
let duoShaderSource = #"""
<file contents>
"""#
```
Commit a generated copy so a plain `swift build` also works. The renderer compiles it at runtime via
`device.makeLibrary(source:options:)` and uses functions `duoVertex` / `duoFragment`.

## Architecture (files under Sources/Duo/)
- `main.swift` — NSApplication, `.accessory` policy, AppDelegate.
- `LidSensor.swift` — HID reader as above. Dedicated `DispatchQueue` + `DispatchSourceTimer`, poll
  rate settable (default 60 Hz, 120 Hz while moving on external power), report 7 with report 1
  fallback chosen once at open. Delivers `Double?` readings on main (nil after 15 consecutive
  failures → "sensor unavailable"). Re-open on failure/wake.
- `LidModel.swift` — turns raw angles into a `FoldState` target + "engaged" flag:
  * Reference (resting) angle: re-anchored when the lid has been still (|Δ| < 0.6° for 1.5 s) at
    any angle — uncapped, so any closing motion from rest is a fold (the "Reveal by" setting, default
    110°, range 60–140, is only the reference when opening from closed/sleep). A move that
    then exceeds a **deadband of 1.0°** below the reference engages the effect. Once engaged,
    target = `FoldState.at(angle:, reference:)`. Disengage (clear) when angle returns within 0.5°
    of the reference OR rises above it, and after the clear animation finishes (see renderer), the
    reference is free to re-anchor at the new resting angle. Hysteresis must guarantee sensor
    jitter never flickers the overlay.
  * Opening after sleep (see README "Opening without lag" — sensor-gap early wake, pre-warm behind
    the lock screen, reveal on `com.apple.screenIsUnlocked`, synthetic Δ42° opening when the lid is
    already open): on `NSWorkspace.didWakeNotification` / `screensDidWakeNotification`, the
    reference is the "Reveal by" setting; if the lid moved while asleep (it was closed, or the first
    reading differs from the pre-sleep angle by more than the deadband) and the current angle is below
    it, engage immediately so the desktop is revealed as the lid opens (this is the iPhone Duo
    "opening" moment). A display that wakes with the lid where it was resumes normally.
  * Lid fully closed (angle < 5°) or built-in display inactive (clamshell) → disengaged, stream stopped.
- `ScreenCapture.swift` — ScreenCaptureKit stream of the built-in display (find via
  `CGDisplayIsBuiltin`), native pixel size, BGRA, `showsCursor = false`, `queueDepth = 3`,
  `minimumFrameInterval` = 1/60 (or 1/120 when allowed), content filter that EXCLUDES OUR OWN
  APPLICATION (`SCContentFilter(display:excludingApplications:[own]:exceptingWindows:[])`) so the
  overlay is never captured recursively. A lock-protected `FrameStore` holding the latest
  `CVPixelBuffer` + revision. Start the stream only while the effect is engaged (plus a short
  grace period before disengaging it, e.g. keep alive 3 s after clear so a re-open is instant);
  stop on sleep. Surface permission state: `CGPreflightScreenCaptureAccess()` /
  `CGRequestScreenCaptureAccess()`; if denied, the menu shows "Grant Screen Recording…" which opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
- `Renderer.swift` — Metal. `MTKView` in the overlay, `bgra8Unorm`, `framebufferOnly`. Capture is
  untagged (no `colorSpaceName`) and the MTKView `colorspace` is nil, so both ends stay in the
  display's own colour space and passthrough is identity regardless of the display preset/profile.
  Per new captured frame: import via `CVMetalTextureCache`, blit into a private mipmapped
  texture of the same size and `generateMipmaps` (so the shader sees a full mip chain, matching the
  harness). Full-screen triangle draw with `DuoUniforms` via `setFragmentBytes`. Triple-buffered with
  a semaphore. Smooth the `FoldState` target toward the current value each frame with an exponential
  approach (time constant ≈ 45 ms for progress/defocus) and a critically damped spring (ω ≈ 1/15 ms)
  for tilt so 0.01° sensor steps never show; a "clear" animates back to zero over 0.5 s with
  `coverage` fading the last 25% so the real desktop takes over seamlessly (`coverage` is also
  applied as the overlay window's alpha). Skip re-encoding when nothing changed; pause the view when
  settled and disengaged. Use the display's max FPS (120) via `preferredFramesPerSecond`.
- `OverlayWindow.swift` — borderless `NSPanel` subclass exactly covering the built-in screen frame,
  `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)`, opaque black
  background, `hasShadow = false`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
  `sharingType = .none`, `canBecomeKey = false`. `orderFrontRegardless()` when engaged (alpha 0
  until the first frame has rendered, then alpha follows coverage), `orderOut` when cleared. Track
  `NSApplication.didChangeScreenParametersNotification` to re-fit / stop when the built-in display
  goes away.
- `Preferences.swift` — `UserDefaults`-backed: perspective (0…1, default 0.7), softness/blur
  (default 0.65), shadow (default 0.65), clearsAt (default 110), enabled (default true),
  launchAtLogin via `SMAppService.mainApp`.
- `StatusMenu.swift` — `NSStatusItem` with SF Symbol `macbook` (or `laptopcomputer`). Menu: Enabled
  toggle, live lid angle + state line (disabled item, updates while the menu is open), "Preview
  Effect" (plays a synthetic close→open over ~4 s without moving the lid — needs screen recording),
  Screen Recording status / "Grant Screen Recording…", Settings…, Launch at Login, Quit.
- `SettingsView.swift` — small SwiftUI window (hosted in NSWindow, `.fullScreenNone`): sliders for
  Perspective / Softness / Shadow, a "Reveal by" angle slider (60–140, shows current angle and a
  "Use current angle" button), Launch at Login, sensor/permission status.
- `AppModel.swift` — `@MainActor` owner that wires sensor → model → capture/renderer/overlay, handles
  sleep/wake, display changes, enabled toggle, preview mode, thermal (`ProcessInfo.thermalState` ≥
  .serious → cap 30 fps) and low-power (60 fps) pacing.

## Behaviour requirements
- Doing nothing must cost nothing: no capture stream, no Metal work, overlay hidden while the lid
  rests. Only the 60 Hz sensor poll runs (it's a cheap HID feature read).
- First engage → overlay must not show a black flash: keep alpha 0 until the first rendered frame.
- Everything on main except the sensor poll, capture callbacks and GPU completion handlers.
- No crash without permission, sensor, or display: degrade to a menu status line.
- `swift build -c release` must succeed with zero errors; keep warnings near zero.

## Deliverables
`Package.swift`, `Sources/Duo/*.swift`, `Tools/gen_shader.sh`, `build_app.sh`, `README.md`
(what it is, how it works, credits: sensor report layout identified by Sam Henri Gold's
LidAngleSensor; inspired by DhananjayBhosale/MacDuo and sumimakito/Mac-Duo).
