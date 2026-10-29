import SwiftUI
import WhaleCore

private let ocean = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.42, green: 0.71, blue: 0.73, alpha: 1)
        : NSColor(red: 0.16, green: 0.38, blue: 0.42, alpha: 1)
})

struct LibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: WhaleBrand.mark).resizable().scaledToFit().frame(width: 48, height: 38).accessibilityHidden(true)
                    Text("whale").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Spacer()
                }.padding(.top, 14)
                Text("A little less to remember.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { model.toggleRecording() } label: {
                    HStack {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                        Text(model.starting ? "Starting…" : model.stopping ? "Saving…" : model.isRecording ? "Stop recording" : "New recording")
                        Spacer()
                        Text("⌘⇧R").font(.caption)
                    }.padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(model.isRecording ? .red : ocean)
                .disabled(model.busy || model.store == nil)
                if let id = model.recordingID, let meeting = model.meetings.first(where: { $0.id == id }) {
                    HStack {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("Recording")
                        Spacer()
                        Text(meeting.date, style: .timer).monospacedDigit()
                    }.font(.caption)
                }
                HStack { Image(systemName: "magnifyingglass"); TextField("Search all meetings", text: $model.query).textFieldStyle(.plain) }
                    .padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                HStack { Text("MEETINGS").tracking(1.5); Spacer(); Text("\(model.meetings.count)") }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                List(selection: $model.selection) {
                    ForEach(model.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            HStack {
                                Text(meeting.date, format: .dateTime.month(.abbreviated).day())
                                Text("·")
                                Text(meeting.status == .ready ? timestamp(meeting.duration) : meeting.status.label)
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 9).tag(meeting.id)
                    }
                }.listStyle(.sidebar).padding(.horizontal, -12)
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Image(systemName: "internaldrive").foregroundStyle(ocean)
                    Text("Your library, on this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help("Settings")
                }.padding(.bottom, 10)
            }.padding(.horizontal, 20)
                .navigationSplitViewColumnWidth(min: 265, ideal: 295, max: 340)
        } detail: {
            if let meeting = model.selected {
                MeetingDetail(model: model, meeting: meeting).id(meeting.id)
            } else {
                VStack(spacing: 18) {
                    Image(nsImage: WhaleBrand.mark).resizable().scaledToFit().frame(width: 130, height: 110).accessibilityHidden(true)
                    Text(model.query.isEmpty ? "Be here. Remember later." : "No matching meetings")
                        .font(.system(size: 30, weight: .medium, design: .serif))
                    Text(model.query.isEmpty ? "Record a conversation, then come back to a clear transcript\nand the things that matter." : "Try a name, a topic, or a phrase from a transcript.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).lineSpacing(5)
                    if model.query.isEmpty {
                        HStack(spacing: 24) {
                            Label("No floating pill", systemImage: "rectangle.slash")
                            Label("Searchable notes", systemImage: "text.magnifyingglass")
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                        Button("Set up AI processing") { model.showingSettings = true }.buttonStyle(.bordered)
                        Text("Captures your microphone and all Mac audio.\nUse headphones for clearer speaker separation.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 15)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(ocean)
        .sheet(isPresented: $model.showingSettings) { SettingsView() }
        .alert("Whale", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.selection) { _, _ in model.stopPlayback() }
    }
}

struct MeetingDetail: View {
    @ObservedObject var model: AppModel
    let meeting: Meeting
    @State private var tab = "Summary"
    @State private var title = ""
    @FocusState private var titleFocused: Bool
    @State private var speakerToEdit: String?
    @State private var speakerName = ""
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(meeting.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    Text("·")
                    Text(timestamp(meeting.duration))
                    Spacer()
                    Text(meeting.status.label).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(ocean.opacity(0.08), in: Capsule()).foregroundStyle(ocean)
                }.font(.caption).foregroundStyle(.secondary)
                TextField("Meeting title", text: $title)
                    .font(.system(size: 29, weight: .medium, design: .serif)).textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { model.rename(meeting.id, title: title); titleFocused = false }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { model.rename(meeting.id, title: title) }
                    }
                    .disabled(model.processingID == meeting.id)
                HStack(spacing: 16) {
                    Picker("View", selection: $tab) { Text("Summary").tag("Summary"); Text("Transcript").tag("Transcript") }
                        .pickerStyle(.segmented).frame(width: 230)
                    Spacer()
                    if !meeting.segments.isEmpty {
                        Button { model.playing ? model.stopPlayback() : model.play(meeting) } label: {
                            Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        }.help("Play recording")
                    }
                    Button { model.export(meeting) } label: { Image(systemName: "square.and.arrow.up") }.help("Export Markdown")
                    Menu {
                        Button("Show saved audio in Finder") {
                            if let folder = try? model.store?.folder(for: meeting.id) { NSWorkspace.shared.open(folder) }
                        }
                        if !meeting.segments.isEmpty {
                            Button("Generate AI title") { model.processMeeting(meeting.id, titleOnly: true) }
                                .disabled(model.isRecording || model.busy)
                            Button("Regenerate summary") { model.processMeeting(meeting.id, summaryOnly: true) }
                                .disabled(model.isRecording || model.busy)
                        }
                        Divider()
                        Button("Delete meeting…", role: .destructive) { deleting = true }
                            .disabled(model.recordingID == meeting.id || model.processingID == meeting.id)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
            }.padding(32)
            Divider()
            if model.processingID == meeting.id {
                HStack { ProgressView().controlSize(.small); Text(model.progress); Spacer(); Button("Cancel") { model.cancelProcessing() } }
                    .font(.callout).padding(16).background(ocean.opacity(0.05))
            }
            if let error = meeting.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if meeting.status == .recording {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Listening, without the clutter.", systemImage: "waveform").font(.title2)
                            Text("You can close this window or hide Whale. Recording continues until you stop it with ⌘⇧R, the menu bar, or the app.")
                            Text("Microphone + all Mac audio · No video saved").font(.caption).foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(ocean.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    } else if tab == "Summary" {
                        if meeting.summary.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("The conversation is saved.").font(.title2)
                                Text("Create a speaker-labeled transcript and a summary of decisions, next steps, and open questions.").foregroundStyle(.secondary)
                                Button("Transcribe & summarize") { model.processMeeting(meeting.id) }
                                    .buttonStyle(.borderedProminent).disabled(model.busy || model.isRecording)
                                Text("AI processing sends this meeting’s audio and transcript to OpenAI. API usage is billed to your account.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(Array(meeting.summary.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                                SummaryBlock(text: paragraph)
                            }
                        }
                    } else if meeting.segments.isEmpty {
                        ContentUnavailableView("No transcript yet", systemImage: "text.alignleft", description: Text("Process this recording to see who said what."))
                    } else {
                        Text("Click a timestamp to listen. Click a speaker name to rename them.")
                            .font(.caption).foregroundStyle(.secondary)
                        if meeting.segments.contains(where: { $0.speaker.hasPrefix("Part ") }) {
                            Text("This recording was split for upload. Speaker labels are independent in each part; rename them to match across the meeting.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(meeting.segments) { segment in
                            HStack(alignment: .top, spacing: 18) {
                                Button(timestamp(segment.start)) { model.play(meeting, at: segment.start) }
                                    .font(.system(.caption, design: .monospaced)).buttonStyle(.plain).foregroundStyle(ocean).frame(width: 62, alignment: .leading)
                                VStack(alignment: .leading, spacing: 7) {
                                    Button(meeting.name(for: segment.speaker)) {
                                        speakerToEdit = segment.speaker; speakerName = meeting.name(for: segment.speaker)
                                    }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ocean)
                                        .disabled(model.processingID == meeting.id)
                                    Text(segment.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: 780, alignment: .leading).padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { title = meeting.title }
        .onChange(of: meeting.title) { _, newTitle in title = newTitle }
        .alert("Rename speaker", isPresented: Binding(get: { speakerToEdit != nil }, set: { if !$0 { speakerToEdit = nil } })) {
            TextField("Name", text: $speakerName)
            Button("Cancel", role: .cancel) { speakerToEdit = nil }
            Button("Save") {
                if let speakerToEdit { model.renameSpeaker(meeting.id, speaker: speakerToEdit, name: speakerName) }
                speakerToEdit = nil
            }
        } message: { Text("Updates this speaker throughout the transcript. Regenerate the summary to use the new name there too.") }
        .confirmationDialog("Delete this meeting and its audio?", isPresented: $deleting) {
            Button("Delete meeting", role: .destructive) { model.delete(meeting) }
        } message: { Text("This removes the local recording, transcript, and summary.") }
    }
}

private struct SummaryBlock: View {
    let text: String
    var body: some View {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 10) {
            if let first = lines.first, first.hasPrefix("#") {
                Text(first.drop(while: { $0 == "#" || $0 == " " }))
                    .font(.system(size: 20, weight: .medium, design: .serif))
                if lines.count > 1 {
                    Text(.init(String(lines[1]))).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                }
            } else {
                Text(.init(text)).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
            }
        }
    }
}
