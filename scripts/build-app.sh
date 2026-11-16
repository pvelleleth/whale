#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-echo.sh
swift build -c release
APP="$PWD/dist/Whale.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Whale "$APP/Contents/MacOS/Whale"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Preserve Sparkle's nested helpers, signatures, and framework symlinks.
mkdir -p "$APP/Contents/Frameworks"
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# Package the SwiftPM image bundle so the installed app does not depend on the build folder.
cp -R .build/release/Whale_WhaleApp.bundle "$APP/Contents/Resources/"
cp -R .build/release/FluidAudio_FluidAudio.bundle "$APP/Contents/Resources/"
cp -R Resources/ThirdPartyNotices "$APP/Contents/Resources/"
# Generate standard macOS icon resolutions from the transparent source artwork.
ICONSET="$PWD/.build/Whale.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Sources/WhaleApp/Resources/WhaleLogo.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Sources/WhaleApp/Resources/WhaleLogo.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Whale.icns"
codesign --force --sign - --identifier app.whale.desktop "$APP"
printf 'Built %s\n' "$APP"
