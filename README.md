# Duo for Mac

Recreates the iPhone "Duo" fold animation on a MacBook. As the lid closes, the desktop appears
to stay locked in space while the screen physically reorients around it — the picture tilts
about the hinge, softens and stretches like peering through a pane of glass. As the lid opens
again, everything comes back into focus. Open the lid after sleep and the desktop is revealed
as the screen swings up.

Menu-bar only. Does nothing (no capture stream, no GPU work, no overlay) while the lid rests;
the only background cost is a cheap 60 Hz feature read of the lid-angle sensor.

## Download

**[⬇ Download Duo.dmg](https://github.com/tobyyu913/Duo/releases/latest/download/Duo.dmg)** — latest
release, ~650 KB. Open the DMG, drag **Duo** to **Applications**, launch it, and grant Screen
Recording when asked. Duo lives in the menu bar (laptop glyph); enable *Launch at Login* from
there if you want it always on.

Duo is signed but not notarized, so the first launch on macOS 15+ goes like this: double-click
Duo → macOS says it *"could not verify"* the app → click **Done** → open **System Settings ›
Privacy & Security**, scroll to the bottom and click **Open Anyway** → confirm. That's a one-time
step; every launch after that is normal.

All releases: <https://github.com/tobyyu913/Duo/releases>

## Requirements

- Apple Silicon MacBook with a lid-angle sensor (verified on a 16" MacBook Pro M4 Max), macOS 15+.
- Screen Recording permission (System Settings › Privacy & Security › Screen Recording). Duo
  asks once on first launch; the menu offers "Grant Screen Recording…" afterwards.
- Xcode / Swift 5.9+ toolchain, only if building from source. No third-party dependencies.

## Build from source

```
./build_app.sh              # build release, assemble Duo.app, sign, install to /Applications
./build_app.sh --no-install # just assemble Duo.app next to the sources
./build_app.sh --dmg        # assemble Duo.app and package it as Duo.dmg (what the releases ship)
./build_app.sh --watch      # rebuild + reinstall + relaunch whenever Sources/ or Shaders/ change
```

The script signs with `Apple Development: yutan@me.com (V2R79MY3H2)` when that identity is in
the keychain (so the Screen Recording grant survives rebuilds) and falls back to ad-hoc signing
otherwise. A plain `swift build -c release` also works; it uses the committed, generated
`Sources/Duo/ShaderSource.swift`.

## Using it

- **Menu bar** (laptop glyph): Enabled toggle, live lid angle and state, Preview Effect (plays a
  synthetic close → open over ~4 s without touching the lid), Screen Recording status,
  Settings…, Launch at Login, Quit.
- **Settings**: Perspective, Softness and Shadow sliders; the "Reveal by" angle (60–140°, with
  the current angle shown and a "Use current angle" button); Launch at Login; sensor and
  permission status.

The resting angle of the lid is re-learned whenever the lid has been still for 1.5 s, wherever
that is. Closing more than 1° below that resting angle starts the effect; coming back to within
0.5° of it (or above it) clears it over half a second and hands the real desktop back.
"Reveal by" (default 110°) only matters when there is no resting angle to measure from — opening
the lid from fully closed or after sleep — and is the angle by which the desktop is fully revealed.

## How it works

```
LidSensor ──60/120 Hz──▶ LidModel ──FoldState target──▶ Renderer ──▶ OverlayWindow
 (IOKit HID)             (deadband, hysteresis,        (Metal, MTKView)   (borderless panel
                          reference re-anchoring)          ▲                 over the screen)
                                                           │
                                          ScreenCapture ───┘ (ScreenCaptureKit, latest frame)
```

- **LidSensor** opens the built-in HID device (vendor 0x05AC, usage page 0x20, usage 0x8A) with
  `IOHIDManager` and polls feature report 7 (`[0x07, b0, b1, b2, b3]`, little-endian hundredths
  of a degree; report 1 with whole degrees is the fallback) on a background queue. No permission
  is needed. Readings are delivered on the main thread; 15 consecutive failures mark the sensor
  unavailable and it is re-opened about once a second (and after wake).
- **LidModel** turns angles into `FoldState.at(angle:reference:)`. The sensor jitters by
  ~0.2° at rest, so engaging needs a 1° move below the reference and clearing happens at 0.5° —
  the two bands never overlap. A lid fully closed (< 5°), an inactive built-in display
  (clamshell) or sleep disengages instantly. After wake, if the lid was closed (or has moved)
  since sleep, the reference is the "Reveal by" angle and the effect engages at once if the lid is
  below it; a display that wakes with the lid where it was simply resumes.
- **ScreenCapture** streams the built-in display at native pixel size (BGRA, no cursor, queue
  depth 3, 60 Hz or 120 Hz on external power) with a content filter that excludes Duo itself,
  so the overlay is never captured recursively. The stream runs only while the effect is engaged,
  plus a 3 s grace period after a clear so a quick re-open is instant.
- **Renderer** imports each frame through a `CVMetalTextureCache`, blits it into a private
  mipmapped texture and generates the mip chain (matching the offline harness), then draws one
  full-screen triangle with `DuoUniforms` (48 bytes, mirrored by the shader's `Uniforms`).
  Progress and defocus approach their target exponentially (τ ≈ 45 ms); tilt runs on a
  critically damped spring (ω ≈ 1/15 ms, closed form so any frame interval is stable), so 0.01°
  sensor steps never show. A clear animates back over 0.5 s with `coverage` fading during the
  last 25 % — `coverage` is also the overlay window's alpha. Frames are triple-buffered; nothing
  is re-encoded when neither the captured frame nor the uniforms changed, and the view pauses
  once a clear has settled. Runs at the display's maximum rate (120 Hz on ProMotion), capped to
  60 in Low Power Mode and 30 under serious thermal pressure.
- **OverlayWindow** is a borderless, non-activating `NSPanel` covering the built-in screen just
  above the status-bar level, ignoring mouse events, joining every Space (including full-screen
  apps) and hidden from screen sharing. It is ordered in at alpha 0 and only becomes visible
  after the first rendered frame has been presented, so there is never a black flash.
- **Shader** (`Shaders/duo.metal`, see `Shaders/CONTRACT.md`) is embedded as a Swift raw string by
  `Tools/gen_shader.sh` (the "anchored glass" effect: a stationary viewer looking through a pane
  hinged at the bottom edge, with a mip-plus-19-tap Gaussian defocus and scalar-only shading) and
  compiled at runtime with `MTLDevice.makeLibrary(source:)`. If `duo.metal` is ever missing the
  script falls back to `Shaders/passthrough.metal`; the header comment of the generated
  `ShaderSource.swift` names whichever file was embedded. Debug builds assert at launch (and again
  when the renderer is created) that `DuoUniforms` is 48 bytes with `size` at offset 16, matching
  the shader's `Uniforms`.

## Opening without lag

Every MacBook fold effect has the same enemy on the way *up*: the sensor is frozen while the Mac
sleeps, macOS posts its wake notification a second or more after the lid started moving, and the
lock screen sits above everything anyway — by the time an app could draw, the lid is open. Duo
attacks that from three sides:

- **Early wake.** The sensor's poll timer keeps running through sleep; the first tick after the
  freeze (a gap of more than a second) is the earliest wake signal there is, well before
  `didWakeNotification`. The HID device is re-opened on the spot.
- **Pre-warm.** As soon as the built-in display is active again, the overlay is ordered in at
  alpha 0 with nothing drawn and the capture stream is started — behind the lock screen — so
  frames are already flowing when the desktop appears.
- **Reveal on unlock.** `com.apple.screenIsUnlocked` (or, with no lock screen, the display coming
  back) is the moment the desktop is visible. If the lid is still rising below "Reveal by", the
  effect follows the real angle; if it is already open — the usual case — a 0.55 s synthetic
  opening plays from Δ42° to clear, then the ordinary half-second clear hands the desktop back.
  The renderer starts *seeded* at the folded state with full coverage, so the first frame is the
  folded desktop, not a fade-in.

Closing gets the same treatment in miniature: the capture stream starts once the lid is 0.45°
below its resting angle, ahead of the 1° engage deadband, so the first frame is ready the moment
the effect engages.

## Poking it from the terminal

```
open duo://preview      # play the synthetic close → open (needs Screen Recording)
open duo://reveal       # play the opening reveal, as if the Mac had just woken
open duo://settings     # open the Settings window
open duo://status       # write a one-line status to the log
log stream --predicate 'subsystem == "com.toby.duo"' --level info   # follow it live
```

The log records sensor status, sleep/early-wake, reveal arming and playback, every phase change
(with angle and reference), overlay show/reveal/hide, capture start/stop, permission changes and
errors.

## Offline shader check (no app launch needed)

`Tools/duo-render` compiles a shader exactly as the app does (`makeLibrary(source:)`,
`duoVertex`/`duoFragment`, `bgra8Unorm`, the same 48-byte `DuoUniforms`) and renders it over a
screenshot at a series of lid deltas. Build it once, then render the shipped shader:

```
Tools/build_render.sh
Tools/duo-render/duo-render Shaders/duo.metal Tools/desktop.png /tmp/duo-out --deltas 0,8,40 --scale 0.25
```

That prints one line per delta (`delta_08: Δ8°  p=0.01  defocus=0.20  tilt=8°`), writes
`delta_<n>.png` per angle plus a labelled `sheet.png` contact sheet, and exits non-zero with the
compiler's diagnostics if the shader fails to compile. Other flags: `--ref 120` (resting angle),
`--perspective`, `--blur`, `--shadow` (0…1, the Settings sliders), `--time`, and `--scale`; at
`--scale 1` the Δ0° frame must be byte-identical to the input screenshot (the contract's
passthrough rule). Point the same command at `Shaders/variant_*.metal` to compare alternatives.

## Layout

```
Package.swift
build_app.sh                 build / sign / install / package DMG (see above)
Sources/Duo/
  main.swift                 NSApplication (.accessory) + AppDelegate
  AppModel.swift             wires everything; sleep/wake, displays, power, preview, pacing
  LidSensor.swift            IOKit HID reader
  LidModel.swift             angle → FoldState target + engaged flag
  FoldState.swift            fold curve + DuoUniforms (fixed; shared with the harness)
  ScreenCapture.swift        ScreenCaptureKit stream + FrameStore
  Renderer.swift             Metal renderer + FoldAnimator
  OverlayWindow.swift        full-screen NSPanel
  Preferences.swift          UserDefaults-backed settings, Launch at Login (SMAppService)
  StatusMenu.swift           NSStatusItem + menu
  SettingsView.swift         SwiftUI settings window
  ShaderSource.swift         GENERATED by Tools/gen_shader.sh
Shaders/
  CONTRACT.md                the Metal interface the app relies on
  duo.metal                  the shipped effect (embedded by gen_shader.sh)
  passthrough.metal          fallback embedded only if duo.metal is missing
  variant_*.metal            alternative looks explored during design; not embedded
Tools/
  gen_shader.sh              embeds the shader into ShaderSource.swift
  build_render.sh, duo-render/   offline shader harness (see above)
  desktop.png                sample screenshot for the harness
```

## Credits

- The lid-angle sensor's HID report layout was identified by Sam Henri Gold's
  [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor).
- Inspired by [DhananjayBhosale/MacDuo](https://github.com/DhananjayBhosale/MacDuo) and
  [sumimakito/Mac-Duo](https://github.com/sumimakito/Mac-Duo).
