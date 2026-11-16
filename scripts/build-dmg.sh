#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
APP="$PWD/dist/Whale.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Whale")
case "$ARCH" in
    arm64) LABEL="apple-silicon" ;;
    x86_64) LABEL="intel" ;;
    "x86_64 arm64"|"arm64 x86_64") LABEL="universal" ;;
    *) echo "Unsupported app architectures: $ARCH" >&2; exit 1 ;;
esac

STAGING=$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Whale.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Read Me.txt" <<'EOF'
Whale — meeting notes for Mac

INSTALL
Drag Whale into Applications, then open Whale from Applications.
If you already have Whale running, quit it before replacing the app.

FIRST LAUNCH
Whale is not notarized by Apple. If macOS blocks it because the developer
cannot be verified, first try opening Whale, then open System Settings >
Privacy & Security and choose Open Anyway for Whale. Only approve a download
you trust. Managed Macs may not allow this exception.
Apple's instructions: https://support.apple.com/102445

REQUIREMENTS
macOS 15 or later. The download filename identifies supported Mac hardware:
apple-silicon for M-series Macs, intel for Intel Macs, universal for both.

SETUP
Allow microphone and system audio recording access when prompted.
Recording works without an API key. To transcribe and summarize, add your own
OpenAI API key in Settings. OpenAI API usage is billed to your OpenAI account.
Live transcription streams audio to OpenAI; summaries send transcript text.
Speaker labeling runs locally. The first live recording downloads a local model.
Echo reduction runs locally before new transcriptions and keeps original audio.

Meetings are saved locally in ~/Library/Application Support/Whale.
EOF

codesign --verify --deep --strict "$STAGING/Whale.app"
NAME="Whale-$VERSION-$LABEL.dmg"
hdiutil create -volname "Whale" -srcfolder "$STAGING" -format UDZO -ov "$PWD/dist/$NAME"
hdiutil verify "$PWD/dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
printf 'Packaged %s\n' "$PWD/dist/$NAME"
