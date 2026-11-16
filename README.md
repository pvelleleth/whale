# Whale

A native macOS meeting notebook: microphone + Mac audio recording with no floating pill, post-meeting speaker-labeled transcription, summaries, and a searchable local library.

## Run

Requires macOS 15 or later, Xcode / Swift 6, and Python 3 to build. The first build downloads and compiles pinned WebRTC AudioProcessing 2.1 and Abseil sources, plus Meson/Ninja build tools in a local virtual environment. Subsequent builds reuse them. WebRTC is statically linked; users do not need separate runtime packages.

```sh
./scripts/build-app.sh
open dist/Whale.app
```

The build creates an ad-hoc-signed app bundle. Launch the `.app`, not `swift run`, so macOS can associate permissions with Whale. For regular use, move the app to `/Applications` and keep its location stable. Unnotarized distribution requires users to approve the app if macOS blocks first launch; Developer ID signing and notarization provide a smoother installation. Ad-hoc rebuilds can cause permissions or Keychain access to be requested again.

1. Open Settings from the sidebar gear or `⌘,`.
2. Add an OpenAI API key and click **Save key**. The key is stored in macOS Keychain, not the project or database. A key is not required for recording.
3. Click **New recording** or press `⌘⇧R`. On first use, allow Microphone and System Audio Recording in macOS. A restart may be required after permission changes.
4. Close the window or hide Whale while recording. There is no app overlay or recording notification. `⌘⇧R` stops recording even while another app is focused. Reopen the library from the Dock. The menu-bar control is optional and off by default.
5. Stop recording, then choose **Transcribe & summarize**. Whale generates a short, context-based meeting title along with the notes. You can enable automatic processing in Settings.
6. Search across meeting titles, summaries, transcripts, and renamed speakers. In the transcript, click a timestamp to play audio and click a speaker label to rename it. The share button exports Markdown.

AI processing uploads audio and transcript content to OpenAI and incurs API usage charges. The local library is under `~/Library/Application Support/Whale/`. There is no cloud account or sync layer. Raw recordings are not encrypted by the app; they use the Mac's filesystem protection. Deleting a meeting removes its local audio and notes.

## What is implemented

- SwiftUI/AppKit desktop app with a quiet library interface.
- Core Audio process tap for Mac audio and AVAudioEngine for the microphone, stored as independent CAF tracks. No ScreenCaptureKit dependency or screen-sharing session. System audio capture uses a private, unmuted audio tap that excludes Whale.
- Recording lifetime independent of window visibility; explicit start/stop; global Carbon shortcut without Accessibility permission.
- SQLite transactions and FTS5 full-text search, with updates when transcripts or speaker names change.
- Audio mixing and size-bounded M4A exports. Completed exports and transcription parts are checkpointed for retry.
- Offline WebRTC AEC3 echo cancellation before new transcription: the aligned system track is the reference for cleaning the microphone track. Processing streams through 48 kHz mono audio in 10 ms frames with bounded memory. Original `microphone.caf` and `system.caf` files are never overwritten; a separate `microphone-aec3-v1.caf` is mixed with system audio for transcription and playback. **More → Show saved audio in Finder** opens all saved originals and derived files.
- Speaker-labeled transcription and timestamped segments using OpenAI's Audio API.
- Transcript-grounded summaries via the Responses API, with section-wise processing for long transcripts.
- AI-generated meeting titles after processing, preserving manually entered names. **More → Generate AI title** also names existing meetings or explicitly regenerates a title. Title-generation errors keep the notes and original title intact.
- Editable titles and per-meeting speaker aliases, Markdown export, timestamp playback, delete confirmation, recoverable processing failures.
- Interrupted recording/processing detection on launch; audio-device format changes and long capture gaps stop and retain the recording rather than silently continuing with invalid data.
- Optional menu-bar control. Recording does not automatically start on launch or join a meeting as a bot.

## Important current limitations

- This is a first local build. Compilation and automated synthetic audio/storage tests pass, but live capture with Zoom/Meet/Teams, OS permissions, screen-share appearance, and real API responses need on-device acceptance testing.
- System audio includes **all applications** except Whale. Pause other audio sources. App-specific selection is not implemented yet.
- macOS controls its own microphone/system-audio privacy indicators; Whale does not suppress them or guarantee invisibility during screen sharing. Unlike v0.1.0, v0.1.1 never opens a screen-capture session. Quit the old app and reopen the rebuilt app to use the new capture path. macOS may request System Audio Recording permission separately; permission naming varies by OS version.
- Echo cancellation reduces speaker bleed but cannot guarantee perfect removal, especially with clipping, changing devices, or unusual acoustics. Synthetic delayed/reverberant echo and overlapping-signal tests cover the offline processor; live speakerphone acceptance testing is still needed. No changes are made to live Zoom/Meet audio. Missing or empty reference tracks skip cleanup. A processing error keeps the originals and reports a retryable failure rather than silently uploading uncleaned audio.
- Existing completed transcripts and their playback are unchanged. New processing uses versioned exports and transcription checkpoints, so legacy pre-cleanup results cannot be reused accidentally. Original recordings remain until the meeting is explicitly deleted. Intermediate resampling files are removed on success, cancellation, or error.
- Speaker labels identify voice clusters, not real names. Rename them manually. Long recordings are split to stay below upload limits, and speakers are intentionally scoped to each part; there is no cross-part voice matching yet.
- Live transcription is available with an OpenAI key. There is no pause/resume control yet; stop and start a new recording instead.
- OpenAI's documented `gpt-4o-transcribe-diarize` model supports `diarized_json` but is scheduled to retire on **February 26, 2027**. This initial implementation uses that supported speaker-labeling path. Before that date, migrate the provider implementation to a supported diarization service; changing to an ordinary transcription model alone will not preserve speaker labels. Model fields are configurable, but response-format compatibility is required.
- Summary references are timestamp text. Transcript timestamps provide playback.
- Raw CAF files are larger than compressed audio and retained for recovery. No automatic retention policy, app-level encryption, cloud sync, automatic updates, or notarized installer yet.

## Architecture

```text
Core Audio tap + AVAudioEngine microphone
                 ↓
        timestamp-aligned CAF tracks
                 ↓
        WebRTC AEC3 cleaned microphone + original system audio
                 ↓
        mixed, size-bounded M4A parts
                 ↓
      speaker-labeled Audio API transcript
                 ↓
       Responses API meeting summary
                 ↓
        local SQLite + FTS5 library
```

- `Sources/WhaleApp/AudioRecorder.swift`: audio-only capture and hardware lifecycle.
- `Sources/WhaleCore/AudioTrackWriter.swift`: timestamp alignment and serial audio writing.
- `Sources/WhaleCore/AudioPreparation.swift`: audio mixing, compression, and resumable manifest.
- `Sources/WhaleCore/EchoCancellation.swift` and `Sources/WhaleAEC/`: streaming offline cleanup and a small C bridge to WebRTC AEC3.
- `scripts/build-echo.sh`: checksum-verified native dependency build. License notices ship in `Contents/Resources/ThirdPartyNotices`.
- `Sources/WhaleCore/AIClient.swift`: transcription/summary API boundary and decoding.
- `Sources/WhaleCore/MeetingStore.swift`: transactional persistence and search indexing.
- `Sources/WhaleApp/AppModel.swift`: recording and processing lifecycle.
- `Sources/WhaleApp/LibraryView.swift`: library, summary, transcript, and speaker editing.

## Verification

### Downloadable disk image

Run `./scripts/build-dmg.sh` to build a release app and a compressed, unnotarized
DMG in `dist/`, with an Applications shortcut, installation instructions, and a
SHA-256 checksum file. The filename includes the version and supported Mac
architecture; a build on Apple Silicon produces an Apple Silicon download.
Publish the DMG and checksum together and label the download as requiring macOS
15 or later. The app uses an ad-hoc signature, not an Apple Developer ID.
Users may need to approve it in System Settings → Privacy & Security → Open Anyway
on first launch. Test a downloaded copy on a separate Mac before public release.

```sh
./scripts/build-echo.sh
swift test
./scripts/build-app.sh
open dist/Whale.app --args --demo
```

Demo mode uses a separate temporary library with an explicitly labeled sample meeting and no audio. It does not record or send API requests automatically. Quit and reopen normally for your real library.

The tests cover database reopen/search/update/delete consistency, interrupted-job recovery, transcription offsets and speaker scoping, Responses output parsing, mixed-sample-rate audio export and reuse, and empty-audio failure.

Echo tests also measure delayed/reverberant echo suppression and independent local-signal retention during overlapping audio, verify original bytes remain unchanged, check short/silent/missing reference tracks and partial final frames, reject legacy export reuse, and exercise cancellation cleanup. These deterministic signal tests are not a substitute for real meeting speech tests.

Before relying on Whale for a meeting:

- Record a short call with headphones and verify both sides in the transcript/playback.
- Check that `⌘⇧R` stops recording while Whale is hidden or its window is closed.
- Verify the actual shared view from a second participant for both full-display and window sharing.
- Deny/regrant audio permissions and check that failure messages preserve the library.
- Disconnect an audio device and test sleep/wake during recording.
- Process a long recording, interrupt processing, and retry; check chunk boundaries and speaker names.

## API references

- [Apple audio-only Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [OpenAI file transcription and diarization](https://developers.openai.com/api/docs/guides/speech-to-text)
- [OpenAI text generation / Responses API](https://developers.openai.com/api/docs/guides/text)

## Live transcription with local speaker labels

Enable **Transcribe live with speaker labels** in Settings. Whale uses your existing
OpenAI key for `gpt-live-transcribe`; no second provider or key is required.
Echo-reduced microphone and Mac audio are streamed to OpenAI while a local
LS-EEND DIHARD III model identifies speaker turns on your Mac. The first live
recording downloads about 45 MB of model files from Hugging Face before capture
starts. Subsequent recordings use the cached model.

Speaker boundaries determine OpenAI audio commits. Each acknowledged transcript
item is associated with its original audio interval, even when completion events
arrive out of order. The API does not provide word timestamps: playback and speaker
labels are turn-level. Unacknowledged text is provisional. Overlapping and uncertain
voices are explicitly labeled; speaker numbers can be renamed to people's names.
The local model supports up to 10 speakers and is best suited to recordings under
an hour. Labels are inferred, not guaranteed identity recognition.

Stopping flushes the local model and the remaining OpenAI turn, then starts notes
generation from the existing transcript. It does not re-upload the whole meeting.
Network latency and summary generation can still vary. If live transcription fails,
original audio remains saved, partial text is marked incomplete, and **Transcribe &
summarize** can recover the recording through the existing file transcription path.
**More → Re-transcribe saved audio** also replaces a live transcript with a file
transcript. Playback reads saved tracks without waiting for an export.

Builds require Swift 6.2 or later. FluidAudio is pinned to 0.17.7 with its optional
NeMo text-normalization dependency disabled. Third-party notices ship in the app.

Validation includes deterministic audio-clock, out-of-order result, speaker-boundary,
network failure, completion-timeout, and persistence tests. The opt-in on-device
integration test generates a two-voice 24 kHz mono WAV fixture and uses the
OpenAI key already stored in Whale's Keychain entry (never prints the key):

```sh
./scripts/test-live.sh
```

macOS may ask you to approve Keychain access for `xctest`.
Use `WHALE_LOCAL_ONLY=1 ./scripts/test-live.sh` to benchmark local inference
without an API call or Keychain access.

On the development M1 Pro, local labeling of a 17.15-second two-voice fixture took
0.43–0.71 seconds, with a roughly 0.02-second final flush (warm cached model).
The full live test, including capture processing and the real OpenAI API, displayed
text before Stop and finalized the transcript 0.95 seconds after Stop. All 27 tests
passed. These measurements exclude summary generation and are not latency guarantees.

Synthetic tests do not establish accuracy for overlapping speech, speakerphones,
or a real Zoom/Meet/Teams meeting.

References:
- [OpenAI live transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [FluidAudio LS-EEND streaming diarization](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Documentation/Diarization/LS-EEND.md)
- [Local model card](https://huggingface.co/FluidInference/ls-eend-coreml)
