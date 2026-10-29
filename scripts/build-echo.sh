#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD/.build/echo-deps"
SOURCE="$ROOT/webrtc-audio-processing-2.1"
if [[ -f "$ROOT/libWhaleWebRTC.a" && -d "$SOURCE/subprojects/abseil-cpp-20240722.0" ]]; then
    exit 0
fi
mkdir -p "$ROOT"
fetch() {
    local url="$1" file="$2" checksum="$3"
    if [[ ! -f "$file" ]]; then curl --fail --location --retry 3 "$url" -o "$file"; fi
    local actual
    actual=$(shasum -a 256 "$file" | cut -d ' ' -f 1)
    [[ "$actual" == "$checksum" ]] || { echo "Checksum mismatch: $file" >&2; exit 1; }
}
fetch https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz "$ROOT/webrtc.tar.xz" ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
if [[ ! -d "$SOURCE" ]]; then tar -xf "$ROOT/webrtc.tar.xz" -C "$ROOT"; fi
CACHE="$SOURCE/subprojects/packagecache"
mkdir -p "$CACHE"
fetch https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz "$CACHE/abseil-cpp-20240722.0.tar.gz" f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
fetch https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch "$CACHE/abseil-cpp_20240722.0-3_patch.zip" 12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b
if [[ ! -x "$ROOT/venv/bin/meson" ]]; then
    python3 -m venv "$ROOT/venv"
    "$ROOT/venv/bin/pip" install meson==1.7.0 ninja==1.11.1.3
fi
export PATH="$ROOT/venv/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=15.0
if [[ ! -f "$ROOT/build/build.ninja" ]]; then
    meson setup "$ROOT/build" "$SOURCE" --buildtype=release --default-library=static --wrap-mode=nodownload \
        -Dc_args=-mmacosx-version-min=15.0 -Dcpp_args=-mmacosx-version-min=15.0 \
        --force-fallback-for=absl_base,absl_flags,absl_strings,absl_numeric,absl_synchronization,absl_bad_optional_access
fi
ninja -C "$ROOT/build" -j 6
# Meson embeds the static dependencies (including Abseil) in the final archive.
cp "$ROOT/build/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a" "$ROOT/libWhaleWebRTC.a"
