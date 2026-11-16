#!/bin/bash
# On-device synthetic speech test. Reads the existing OpenAI key through Keychain;
# only the generated fixture audio is sent to OpenAI. No key is printed or written.
set -euo pipefail
cd "$(dirname "$0")/.."
FIXTURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/whale-live-test.XXXXXX")
trap 'rm -rf "$FIXTURE_DIR"' EXIT
say -v Samantha -r 160 -o "$FIXTURE_DIR/a.aiff" 'We should finish the project by Friday. I will prepare the design and review the final results.'
say -v Daniel -r 160 -o "$FIXTURE_DIR/b.aiff" 'That sounds good to me. I will handle the testing and share a report with everyone tomorrow.'
for voice in a b; do
    afconvert -f WAVE -d LEI16@24000 -c 1 "$FIXTURE_DIR/$voice.aiff" "$FIXTURE_DIR/$voice.wav"
done
python3 - "$FIXTURE_DIR" <<'PY'
import pathlib, sys, wave
folder = pathlib.Path(sys.argv[1])
with wave.open(str(folder / 'fixture.wav'), 'wb') as out:
    out.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
    for voice in ['a', 'b', 'a']:
        with wave.open(str(folder / (voice + '.wav')), 'rb') as source:
            out.writeframes(source.readframes(source.getnframes()))
        out.writeframes(bytes(24000))
PY
WHALE_LIVE_TEST=1 WHALE_TEST_AUDIO="$FIXTURE_DIR/fixture.wav" swift test -c release --filter LiveIntegrationTests
