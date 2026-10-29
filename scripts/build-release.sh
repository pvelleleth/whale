#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The private signing key stays in this Mac's login Keychain, never in public/.
swift package resolve
TOOLS="$PWD/.build/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY=$("$TOOLS/generate_keys" --account app.whale.desktop -p)
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
if [[ "$PUBLIC_KEY" != "$EXPECTED_KEY" ]]; then
    echo 'Signing key does not match Whale. Restore the original Keychain key before releasing.' >&2
    exit 1
fi
python3 - <<'PY'
import pathlib, plistlib, xml.etree.ElementTree as ET
info = plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
feed = pathlib.Path('landing-page/public/updates/appcast.xml')
if feed.exists():
    versions = [int(e.text) for e in ET.parse(feed).iter('{http://www.andymatuschak.org/xml-namespaces/sparkle}version')]
    if versions and int(info['CFBundleVersion']) <= max(versions):
        raise SystemExit('Increment CFBundleVersion and CFBundleShortVersionString before releasing.')
PY
./scripts/build-dmg.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Whale.app/Contents/Info.plist)
ARCH=$(lipo -archs dist/Whale.app/Contents/MacOS/Whale)
# This feed currently serves the Apple Silicon download advertised by the site.
[[ "$ARCH" == arm64 ]] || { echo 'This release feed requires an Apple Silicon build.' >&2; exit 1; }
NAME="Whale-$VERSION-apple-silicon.dmg"
STAGING=$(mktemp -d "$PWD/.build/update-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
cp "dist/$NAME" "$STAGING/"
"$TOOLS/generate_appcast" --account app.whale.desktop --maximum-deltas 0 \
    --download-url-prefix https://whalenote.app/downloads/ \
    --link https://whalenote.app "$STAGING"
mkdir -p landing-page/public/updates
cp "$STAGING/appcast.xml" landing-page/public/updates/appcast.xml
cp "dist/$NAME" "dist/$NAME.sha256" landing-page/public/downloads/
python3 - "$NAME" "$VERSION" <<'PY'
import pathlib, re, sys
name, version = sys.argv[1:]
p = pathlib.Path('landing-page/public/index.html')
s = re.sub(r'Whale-[0-9.]+-apple-silicon\.dmg', name, p.read_text())
s = re.sub(r'v\d+\.\d+\.\d+', 'v' + version, s)
size = pathlib.Path('dist', name).stat().st_size / 1_000_000
s = re.sub(r'macOS 15\+ · [\d.]+ MB', f'macOS 15+ · {size:.1f} MB', s)
p.write_text(s)
PY
printf 'Release prepared. Deploy landing-page/ to whalenote.app to publish it.\n'
