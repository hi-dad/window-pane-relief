#!/usr/bin/env bash
# Builds "build/Window Pane Relief.app" and installs it in /Applications.
# ./scripts/build-app.sh dist  also makes dist/WindowPaneRelief.dmg to share.
# Calls swiftc directly instead of `swift build`, so it still works when the Command Line
# Tools' package manager is broken ("Invalid manifest" / PackageDescription link errors).
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/sparkle.sh && sparkle_fetch   # self-updating (see tools/sparkle.sh)

APP="build/Window Pane Relief.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple Silicon + Intel Macs.
for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos13 \
        -framework AppKit \
        -framework ApplicationServices \
        -framework Carbon \
        -framework ScreenCaptureKit \
        "${SPARKLE_SWIFTC_FLAGS[@]}" \
        Sources/WindowPin/*.swift \
        -o "build/WindowPaneRelief-$arch"
done
lipo -create build/WindowPaneRelief-arm64 build/WindowPaneRelief-x86_64 -output "$APP/Contents/MacOS/WindowPaneRelief"
rm build/WindowPaneRelief-arm64 build/WindowPaneRelief-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/"
sparkle_embed "$APP"
sparkle_plist "$APP" window-pane-relief
# Sign with the same local certificate every time so macOS keeps Screen Recording and Accessibility
# across rebuilds. (Falls back to ad-hoc signing on a Mac without it; then they must be re-granted.)
# GitHub's release builds sign with Developer ID + hardened runtime + timestamp, as Apple's notarization needs.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    sparkle_sign "$APP" --force --sign "$SIGN_IDENTITY" --options runtime --timestamp
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
elif security find-certificate -c "Daniel Ryan Local Signing" >/dev/null 2>&1; then
    sparkle_sign "$APP" --force --sign "Daniel Ryan Local Signing"
    codesign --force --sign "Daniel Ryan Local Signing" "$APP"
else
    sparkle_sign "$APP" --force --sign -
    codesign --force --sign - "$APP"
fi

echo "Built $APP"

if [[ "${1:-}" == "dist" ]]; then
  rm -rf dist && mkdir -p dist/stage
  cp -R "$APP" dist/stage/
  ln -s /Applications dist/stage/Applications
  hdiutil create -volname "Window Pane Relief" -srcfolder dist/stage -ov -format UDZO dist/WindowPaneRelief.dmg >/dev/null
  rm -rf dist/stage
  echo "Made dist/WindowPaneRelief.dmg"
fi

# On GitHub's build machines (CI is set there), stop here: the DMG is what gets published.
[[ -n "${CI:-}" ]] && exit 0

# Replace any installed copy, quitting it first if it's running.
pkill -x WindowPaneRelief 2>/dev/null && sleep 1 || true
pkill -x WindowPin 2>/dev/null && sleep 1 || true   # its name before Window Pane Relief
rm -rf "/Applications/Window Pin.app"
rm -rf "/Applications/Window Pane Relief.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Window Pane Relief.app"

open "/Applications/Window Pane Relief.app"
