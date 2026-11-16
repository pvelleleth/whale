import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showMenuBar") private var showMenuBar = false
    @AppStorage("liveTranscription") private var liveTranscription = true
    @AppStorage("autoProcess") private var autoProcess = false
    @AppStorage("transcriptionModel") private var transcriptionModel = "gpt-4o-transcribe-diarize"
    @AppStorage("summaryModel") private var summaryModel = "gpt-6-luna"
    @ObservedObject private var updater = AppUpdater.shared
    @State private var key = ""
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Make yourself at home.").font(.system(size: 25, weight: .medium, design: .serif)); Spacer(); Button("Done") { dismiss() } }
            Form {
                Section("AI processing") {
                    SecureField("OpenAI API key", text: $key)
                    HStack { Button("Save key") { save() }; Text(message).font(.caption).foregroundStyle(.secondary) }
                    Text("Stored in macOS Keychain. Recording works without a key. Transcription uploads audio to OpenAI; summaries send the transcript. API usage is billed separately.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Transcribe live with speaker labels", isOn: $liveTranscription)
                    Text("Streams audio to OpenAI for live text. Speaker labeling runs locally on your Mac; the model downloads once before the first live recording. OpenAI writes notes when you stop. Uses your existing API key. Speaker labels are inferred, and overlapping or uncertain voices may be unlabeled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Process automatically when live transcription is off", isOn: $autoProcess)
                }
                Section("Recording") {
                    Toggle("Show an optional menu-bar control", isOn: $showMenuBar)
                    LabeledContent("Start / stop from anywhere", value: "⌘ ⇧ R")
                    Text("No floating pill or recording notifications. Closing the window keeps recording. macOS privacy indicators remain visible. Captures your microphone and all Mac audio; headphones reduce echo.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Echo reduction runs on your Mac during live transcription and before file transcription. Original recordings are kept alongside the cleaned audio. Your live meeting audio is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Models") {
                    TextField("File speaker-labeling model", text: $transcriptionModel)
                    TextField("Summary model", text: $summaryModel)
                    Text("Live text uses gpt-live-transcribe. Local speaker labeling uses LS-EEND (up to 10 speakers, best suited to meetings under an hour). Names can be assigned afterward. The file transcription model must support diarized_json.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Updates") {
                    Toggle("Automatically download and install updates", isOn: Binding(get: { updater.automaticallyUpdates }, set: { updater.automaticallyUpdates = $0 }))
                    Text("Updates are installed when Whale quits. Recording and processing are allowed to finish first.").font(.caption).foregroundStyle(.secondary)
                    if let error = updater.configurationError { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Storage") {
                    Text("Meetings and audio are stored locally in ~/Library/Application Support/Whale. Cloud sync is not enabled. Delete a meeting to remove its local audio and notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 620, height: 740)
            .onAppear { do { key = try Keychain.load() } catch { message = error.localizedDescription } }
    }
    private func save() {
        do { try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); message = key.isEmpty ? "Key removed." : "Saved to Keychain." }
        catch { message = error.localizedDescription }
    }
}
