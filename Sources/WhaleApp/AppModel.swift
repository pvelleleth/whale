import AppKit
import AVFoundation
import Combine
import WhaleCore

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selection: UUID?
    @Published var query = "" { didSet { reload() } }
    @Published var recordingID: UUID?
    @Published var processingID: UUID?
    @Published var starting = false
    @Published var stopping = false
    @Published var progress = ""
    @Published var error: String?
    @Published var showingSettings = false
    @Published var playing = false
    private(set) var store: MeetingStore?
    private let recorder = AudioRecorder()
    private var processingTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var playbackObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var hotKey: GlobalHotKey?
    private var activity: NSObjectProtocol?

    var isRecording: Bool { recordingID != nil }
    var busy: Bool { starting || stopping || processingID != nil }
    var selected: Meeting? { meetings.first { $0.id == selection } }

    init() {
        do {
            let demo = ProcessInfo.processInfo.arguments.contains("--demo")
            let root = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("Whale-Demo") :
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Whale")
            store = try MeetingStore(root: root)
            try store?.recoverInterrupted()
            if demo, try store?.load().isEmpty == true { try addDemo() }
            reload(); selection = meetings.first?.id
        } catch { self.error = error.localizedDescription }
        recorder.onFailure = { [weak self] message in
            Task { @MainActor in await self?.stopRecording(captureError: message) }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                await self.stopRecording(captureError: "Recording stopped because your Mac went to sleep. Saved audio is available for processing.")
            }
        }
    }
    func installHotKey() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
        if hotKey?.registered == false { error = "The global shortcut ⌘⇧R is already in use. You can still record from the app or menu bar." }
    }
    func reload() {
        do { meetings = try store?.load(query: query) ?? [] }
        catch { self.error = error.localizedDescription }
    }
    func update(_ meeting: Meeting) throws {
        guard let store else { throw WhaleError("The meeting library is unavailable.") }
        try store.save(meeting); reload()
    }
    func rename(_ id: UUID, title: String) {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard meeting.title != title, processingID != id else { return }
        meeting.title = title
        meeting.titleSource = .manual
        do { try update(meeting) } catch { self.error = error.localizedDescription }
    }
    func renameSpeaker(_ id: UUID, speaker: String, name: String) {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakerNames[speaker] = trimmed.isEmpty ? nil : trimmed
        do { try update(meeting) } catch { self.error = error.localizedDescription }
    }
    func toggleRecording() {
        guard !busy else { return }
        Task { if isRecording { await stopRecording() } else { await startRecording() } }
    }
    private func startRecording() async {
        guard let store, !isRecording else { return }
        starting = true
        stopPlayback()
        defer { starting = false }
        var meeting = Meeting(title: "Meeting · \(Date().formatted(date: .abbreviated, time: .shortened))", status: .recording)
        meeting.titleSource = .placeholder
        do {
            let folder = try store.folder(for: meeting.id)
            try update(meeting)
            query = ""; selection = meeting.id
            try await recorder.start(folder: folder)
            recordingID = meeting.id
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a meeting")
        } catch {
            await recorder.stop()
            meeting.status = .failed; meeting.error = error.localizedDescription
            try? update(meeting)
            self.error = "Could not start recording: \(error.localizedDescription)"
        }
    }
    func stopRecording(captureError: String? = nil, process: Bool = true) async {
        guard let id = recordingID, !stopping else { return }
        stopping = true
        defer { stopping = false }
        let trackWarning = await recorder.stop()
        let captureError = captureError ?? trackWarning
        recordingID = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        do {
            guard var meeting = try store?.load().first(where: { $0.id == id }) else { return }
            meeting.duration = max(0, Date().timeIntervalSince(meeting.date))
            meeting.status = captureError == nil ? .recorded : .interrupted
            meeting.error = captureError
            try update(meeting)
            if let captureError { error = captureError }
            else if process, UserDefaults.standard.bool(forKey: "autoProcess"), !(try Keychain.load()).isEmpty {
                processMeeting(id)
            }
        } catch { self.error = error.localizedDescription }
    }
    func processMeeting(_ id: UUID, summaryOnly: Bool = false, titleOnly: Bool = false) {
        guard processingID == nil, !isRecording, let store else { return }
        do {
            let key = try Keychain.load()
            guard !key.isEmpty else { showingSettings = true; return }
            guard let meeting = try store.load().first(where: { $0.id == id }) else { return }
            let client = AIClient(configuration: AIConfiguration(apiKey: key,
                transcriptionModel: UserDefaults.standard.string(forKey: "transcriptionModel") ?? "gpt-4o-transcribe-diarize",
                summaryModel: UserDefaults.standard.string(forKey: "summaryModel") ?? "gpt-4.1-mini"))
            processingID = id
            processingTask = Task { [weak self] in
                guard let self else { return }
                var working = meeting
                defer { processingID = nil; processingTask = nil; progress = "" }
                do {
                    working.status = .processing; working.error = nil; try update(working)
                    if !summaryOnly && !titleOnly && working.segments.isEmpty {
                        progress = "Preparing audio…"
                        let folder = try store.folder(for: id)
                        let parts = try await AudioPreparation.prepare(folder: folder)
                        var segments: [Segment] = []
                        for (index, part) in parts.enumerated() {
                            try Task.checkCancellation()
                            progress = "Transcribing part \(index + 1) of \(parts.count)…"
                            let checkpoint = folder.appendingPathComponent("transcript-\(index).json")
                            if let data = try? Data(contentsOf: checkpoint), let cached = try? JSONDecoder().decode([Segment].self, from: data) {
                                segments += cached
                            } else {
                                let result = try await client.transcribe(file: folder.appendingPathComponent(part.filename), offset: part.offset, part: index, multipleParts: parts.count > 1)
                                try JSONEncoder().encode(result).write(to: checkpoint, options: .atomic)
                                segments += result
                            }
                        }
                        working.segments = segments.sorted { $0.start < $1.start }
                        working.duration = parts.map { $0.offset + $0.duration }.max() ?? working.duration
                        try update(working)
                    }
                    if !titleOnly {
                        progress = "Writing the summary…"
                        working.summary = try await client.summarize(working)
                        try update(working)
                    }
                    var titleWarning: String?
                    if working.needsAutomaticTitle || titleOnly {
                        progress = "Naming the meeting…"
                        do {
                            let generated = try await client.generateTitle(working)
                            try Task.checkCancellation()
                            working.applyGeneratedTitle(generated, replacingExisting: titleOnly)
                        } catch {
                            if Task.isCancelled { throw error }
                            titleWarning = "Your notes are saved, but the meeting title could not be generated. Use More → Generate AI title to retry. \(error.localizedDescription)"
                        }
                    }
                    working.status = titleOnly ? meeting.status : .ready
                    working.error = titleWarning ?? (titleOnly && meeting.status != .ready ? meeting.error : nil)
                    try update(working)
                } catch {
                    working.status = .failed
                    working.error = Task.isCancelled ? "Processing cancelled. Saved audio and completed transcription parts are retained." : error.localizedDescription
                    do { try update(working) } catch { self.error = error.localizedDescription }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancelProcessing() { processingTask?.cancel() }
    func play(_ meeting: Meeting, at seconds: Double = 0) {
        do {
            guard let folder = try store?.folder(for: meeting.id) else { return }
            let parts = try JSONDecoder().decode([AudioPart].self, from: Data(contentsOf: folder.appendingPathComponent("parts.json")))
            guard let part = parts.last(where: { $0.offset <= seconds }) else { return }
            stopPlayback()
            let player = AVPlayer(url: folder.appendingPathComponent(part.filename))
            self.player = player
            player.seek(to: CMTime(seconds: max(0, seconds - part.offset), preferredTimescale: 600))
            player.play(); playing = true
            playbackObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let next = parts.first(where: { $0.offset >= part.offset + part.duration - 0.01 && $0.offset > part.offset }) { self.play(meeting, at: next.offset) }
                    else { self.stopPlayback() }
                }
            }
        } catch { self.error = "Playback is available after audio preparation. \(error.localizedDescription)" }
    }
    func stopPlayback() {
        player?.pause(); player = nil; playing = false
        if let playbackObserver { NotificationCenter.default.removeObserver(playbackObserver); self.playbackObserver = nil }
    }
    func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try meeting.markdown.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
    func delete(_ meeting: Meeting) {
        guard meeting.id != recordingID, meeting.id != processingID else { return }
        do { stopPlayback(); try store?.delete(meeting.id); reload(); selection = meetings.first?.id }
        catch { self.error = error.localizedDescription }
    }
    private func addDemo() throws {
        var demo = Meeting(title: "Designing a quieter workspace", date: Date().addingTimeInterval(-3600), duration: 1128, status: .ready,
            segments: [Segment(start: 12, end: 18, speaker: "A", text: "Let's keep recording out of the way. I want to close the window and focus on the conversation."),
                       Segment(start: 19, end: 28, speaker: "B", text: "Agreed. We'll put transcripts and summaries together in a searchable meeting library."),
                       Segment(start: 35, end: 42, speaker: "A", text: "I'll test the audio capture on Friday. Let's leave live transcription for a later version.")],
            summary: "## Overview\nA quieter meeting workflow with one place for notes.\n\n## Decisions\n• Keep the recording interface out of the way. [00:12]\n• Save transcripts and summaries in a searchable library. [00:19]\n• Defer live transcription. [00:35]\n\n## Action items\n• Alex: test audio capture on Friday. [00:35]\n\n## Open questions\n• None explicitly raised.\n\n*Sample meeting — no real audio was recorded.*")
        demo.speakerNames = ["A": "Alex", "B": "Sam"]
        try store?.save(demo)
    }
}
