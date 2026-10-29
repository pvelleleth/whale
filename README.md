# Whale

A native macOS meeting notebook: microphone + Mac audio recording with no floating pill, post-meeting speaker-labeled transcription, summaries, and a searchable local library.

## Run

Requires macOS 15 or later and Xcode / Swift 6 to build. No third-party packages are required.

```sh
./scripts/build-app.sh
open dist/Whale.app
```

The build creates an ad-hoc-signed app bundle. Launch the `.app`, not `swift run`, so macOS can associate permissions with Whale. For regular use, move the app to `/Applications` and keep its location stable. Developer ID signing and notarization are still needed for distribution to other users; ad-hoc rebuilds can cause permissions or Keychain access to be requested again.

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
- Use headphones: speaker output picked up by the microphone can create echo or duplicate speech. Acoustic echo cancellation is not implemented.
- Speaker labels identify voice clusters, not real names. Rename them manually. Long recordings are split to stay below upload limits, and speakers are intentionally scoped to each part; there is no cross-part voice matching yet.
- Transcription is post-meeting, not live. There is no pause/resume control yet; stop and start a new recording instead.
- OpenAI's documented `gpt-4o-transcribe-diarize` model supports `diarized_json` but is scheduled to retire on **February 26, 2027**. This initial implementation uses that supported speaker-labeling path. Before that date, migrate the provider implementation to a supported diarization service; changing to an ordinary transcription model alone will not preserve speaker labels. Model fields are configurable, but response-format compatibility is required.
- Summary references are timestamp text. Transcript timestamps provide playback.
- Raw CAF files are larger than compressed audio and retained for recovery. No automatic retention policy, app-level encryption, cloud sync, automatic updates, or notarized installer yet.

## Architecture

```text
Core Audio tap + AVAudioEngine microphone
                 ↓
        timestamp-aligned CAF tracks
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
- `Sources/WhaleCore/AIClient.swift`: transcription/summary API boundary and decoding.
- `Sources/WhaleCore/MeetingStore.swift`: transactional persistence and search indexing.
- `Sources/WhaleApp/AppModel.swift`: recording and processing lifecycle.
- `Sources/WhaleApp/LibraryView.swift`: library, summary, transcript, and speaker editing.

## Verification

```sh
swift test
./scripts/build-app.sh
open dist/Whale.app --args --demo
```

Demo mode uses a separate temporary library with an explicitly labeled sample meeting and no audio. It does not record or send API requests automatically. Quit and reopen normally for your real library.

The tests cover database reopen/search/update/delete consistency, interrupted-job recovery, transcription offsets and speaker scoping, Responses output parsing, mixed-sample-rate audio export and reuse, and empty-audio failure.

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
