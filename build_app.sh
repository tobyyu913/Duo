#!/bin/bash
#
# Build "Duo.app", sign it, and install to /Applications.
#
#   ./build_app.sh              build + install once
#   ./build_app.sh --no-install build the .app next to the sources only
#   ./build_app.sh --dmg        build the .app and package it as Duo.dmg (no install)
#   ./build_app.sh --watch      rebuild + reinstall + relaunch on every change
#
# Signs with the Apple Development identity when it is present so the Screen Recording
# grant survives rebuilds; falls back to ad-hoc signing otherwise.
#
set -euo pipefail

APP_NAME="Duo"
EXEC_NAME="Duo"
BUNDLE_ID="com.toby.duo"
SIGN_IDENTITY="Apple Development: yutan@me.com (V2R79MY3H2)"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/$APP_NAME.app"
CONTENTS="$APP/Contents"
DEST="/Applications/$APP_NAME.app"
DMG="$HERE/$APP_NAME.dmg"

make_icon() {
  set +e
  local icns="$1"
  local tmp; tmp="$(mktemp -d)"
  local gen="$tmp/gen.swift"
  local master="$tmp/master.png"

  cat > "$gen" <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let inset: CGFloat = 64
let r = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let bg = NSBezierPath(roundedRect: r, xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.16, green: 0.20, blue: 0.34, alpha: 1),
           ending:   NSColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1))!
    .draw(in: bg, angle: -90)
// Screen glow "locked in space" behind the lid: a soft frosted pane.
let pane = NSBezierPath(roundedRect: NSRect(x: 300, y: 380, width: 420, height: 300), xRadius: 36, yRadius: 36)
NSGradient(starting: NSColor(red: 0.55, green: 0.78, blue: 1.00, alpha: 0.55),
           ending:   NSColor(red: 0.90, green: 0.60, blue: 1.00, alpha: 0.15))!
    .draw(in: pane, angle: -60)
// A laptop seen from the side, lid half closed: the base…
let baseRect = NSRect(x: 200, y: 300, width: 624, height: 52)
NSColor(white: 0.92, alpha: 1).setFill()
NSBezierPath(roundedRect: baseRect, xRadius: 26, yRadius: 26).fill()
// …and the lid, tilted about the hinge at the back.
let lid = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 560, height: 40), xRadius: 20, yRadius: 20)
var tilt = AffineTransform(translationByX: 236, byY: 352)
tilt.rotate(byDegrees: 42)
lid.transform(using: tilt)
NSColor(white: 0.92, alpha: 1).setFill()
lid.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT
  swift "$gen" "$master" >/dev/null 2>&1 || { rm -rf "$tmp"; set -e; return 1; }

  local set_dir="$tmp/AppIcon.iconset"; mkdir -p "$set_dir"
  declare -a names=( icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 \
                     icon_128x128:128 icon_128x128@2x:256 icon_256x256:256 \
                     icon_256x256@2x:512 icon_512x512:512 icon_512x512@2x:1024 )
  for n in "${names[@]}"; do
    sips -z "${n##*:}" "${n##*:}" "$master" --out "$set_dir/${n%%:*}.png" >/dev/null 2>&1
  done

  iconutil -c icns "$set_dir" -o "$icns" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  set -e
  return $rc
}

sign_app() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
    echo "==> codesign ($SIGN_IDENTITY)"
    codesign --force --timestamp=none --identifier "$BUNDLE_ID" -s "$SIGN_IDENTITY" "$APP" || return 1
  else
    echo "==> codesign (ad-hoc; identity not found)"
    codesign --force --identifier "$BUNDLE_ID" -s - "$APP" || return 1
  fi
  codesign --verify --strict "$APP" && echo "    signature OK"
}

build_and_install() {
  echo "==> embedding shader"
  "$HERE/Tools/gen_shader.sh" || { echo "==> shader embed failed"; return 1; }

  echo "==> swift build -c release"
  # Explicit returns: `set -e` is suspended inside a function used as an if-condition
  # (the --watch loop), which would otherwise package and relaunch the stale binary.
  swift build -c release --package-path "$HERE" || { echo "==> build failed — keeping the installed app"; return 1; }
  local bin="$HERE/.build/release/$EXEC_NAME"

  echo "==> assembling $APP_NAME.app"
  rm -rf "$APP"
  mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
  cp "$bin" "$CONTENTS/MacOS/$EXEC_NAME"

  local icon_key=""
  if make_icon "$CONTENTS/Resources/AppIcon.icns"; then
    icon_key="<key>CFBundleIconFile</key><string>AppIcon</string>"
    echo "    icon: generated"
  else
    echo "    icon: skipped (using default)"
  fi

  cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>          <string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.utilities</string>
    <key>LSUIElement</key>                 <true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key>    <string>$BUNDLE_ID</string>
        <key>CFBundleURLSchemes</key> <array><string>duo</string></array>
    </dict></array>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Duo redraws a blurred, tilted copy of your desktop while the lid closes. It needs to see the screen to do that; nothing is recorded or stored.</string>
    $icon_key
</dict>
</plist>
PLIST

  printf 'APPL????' > "$CONTENTS/PkgInfo"

  sign_app || { echo "==> codesign failed"; return 1; }

  if [[ "${NO_INSTALL:-0}" == "1" ]]; then
    echo "==> built: $APP"
  else
    echo "==> installing to $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "    done"
  fi
}

make_dmg() {
  echo "==> packaging $APP_NAME.dmg"
  local stage; stage="$(mktemp -d)"
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  rm -f "$DMG"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$DMG" \
    || { rm -rf "$stage"; echo "==> hdiutil failed"; return 1; }
  rm -rf "$stage"
  echo "    built: $DMG ($(du -h "$DMG" | cut -f1))"
}

sources_signature() {
  find "$HERE/Sources" "$HERE/Shaders" "$HERE/Tools/gen_shader.sh" "$HERE/Package.swift" -type f \
    -not -name ShaderSource.swift -exec stat -f '%m %N' {} + 2>/dev/null \
    | sort | shasum | awk '{print $1}'
}

case "${1:-}" in
  --no-install)
    NO_INSTALL=1 build_and_install
    ;;
  --dmg)
    NO_INSTALL=1 build_and_install && make_dmg
    ;;
  --watch)
    echo "Watching Sources/ and Shaders/ — edit a file and the installed app updates automatically."
    echo "Press Ctrl-C to stop."
    build_and_install
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    open "$DEST"
    last="$(sources_signature)"
    while true; do
      sleep 1
      cur="$(sources_signature)"
      if [[ "$cur" != "$last" ]]; then
        echo ""
        echo "==> change detected, rebuilding…"
        if build_and_install; then
          pkill -x "$EXEC_NAME" 2>/dev/null || true
          open "$DEST"
        else
          echo "==> not relaunched; fix the error and save again"
        fi
        last="$cur"
      fi
    done
    ;;
  *)
    build_and_install
    ;;
esac
