import Foundation

public struct LiveTranscriptUpdate: Sendable {
    public let segments: [Segment]
    public let interim: [Segment]
}

/// Commit acknowledgements, rather than network arrival times, associate text with audio turns.
struct LiveTranscript {
    struct Turn {
        var segment: Segment
        var itemID: String?
    }
    var turns: [Turn] = []
    var pending: [Int] = []
    var text: [String: String] = [:]
    var completed: Set<String> = []
    var active: Int?
    mutating func begin(start: Double, end: Double, speaker: String) {
        turns.append(Turn(segment: Segment(start: start, end: end, speaker: speaker, text: "")))
        active = turns.count - 1
    }
    mutating func commit() {
        if let active { pending.append(active) }
        active = nil
    }
    mutating func acknowledge(_ item: String) throws {
        guard !turns.contains(where: { $0.itemID == item }) else { return }
        guard !pending.isEmpty else { throw WhaleError("Unexpected live transcription acknowledgement.") }
        turns[pending.removeFirst()].itemID = item
    }
    var isComplete: Bool { active == nil && pending.isEmpty && turns.allSatisfy { $0.itemID.map(completed.contains) == true } }
    var segments: [Segment] {
        turns.compactMap { turn in
            guard let item = turn.itemID, completed.contains(item), let value = text[item], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var segment = turn.segment; segment.text = value; return segment
        }
    }
    var interim: [Segment] {
        var result = turns.compactMap { turn -> Segment? in
            guard let item = turn.itemID, !completed.contains(item), let value = text[item], !value.isEmpty else { return nil }
            var segment = turn.segment; segment.text = value; return segment
        }
        // With no pending acknowledgements, an unbound draft belongs to the active audio
        // turn. Otherwise its speaker stays provisional until its item is acknowledged.
        let bound = Set(turns.compactMap(\.itemID))
        for item in text.keys.sorted().filter({ !bound.contains($0) }).prefix(1) {
            guard let index = pending.first ?? active, let value = text[item], !value.isEmpty else { continue }
            var segment = turns[index].segment
            if !pending.isEmpty { segment.speaker = "Identifying speaker…" }
            segment.text = value
            result.append(segment)
        }
        return result
    }
}

protocol LiveTranscriptionTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

final class LiveWebSocket: LiveTranscriptionTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(apiKey: String) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }
    func send(_ data: Data) async throws { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw WhaleError("Unsupported live transcription event.")
        }
    }
    func close() async { task.cancel(with: .normalClosure, reason: nil) }
}

public actor LiveTranscriber {
    private let transport: any LiveTranscriptionTransport
    private let onUpdate: @Sendable (LiveTranscriptUpdate) async -> Void
    private var receiver: Task<Void, Never>?
    private var ledger = LiveTranscript()
    private var closed = false
    private var ready = false
    private var failure: String?
    private var turnBytes = 0
    private let finishTimeout: Double

    public init(apiKey: String, onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void) {
        transport = LiveWebSocket(apiKey: apiKey); self.onUpdate = onUpdate; finishTimeout = 10
    }
    init(transport: any LiveTranscriptionTransport, finishTimeout: Double = 10, onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void) {
        self.transport = transport; self.onUpdate = onUpdate; self.finishTimeout = finishTimeout
    }
    public func start() async throws {
        receiver = Task { [weak self] in await self?.receiveEvents() }
        try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": ["model": "gpt-live-transcribe", "delay": "low"], "turn_detection": NSNull()
        ]]]])
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !ready {
            try check()
            guard ContinuousClock.now < deadline else { throw WhaleError("OpenAI did not initialize live transcription.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    public func append(_ pcm: Data, start: Double, end: Double, speaker: String) async throws {
        try check()
        guard !pcm.isEmpty else { return }
        if let active = ledger.active {
            let previous = ledger.turns[active].segment
            if previous.speaker != speaker || start - previous.end > 0.05 || previous.end - previous.start >= 10 {
                try await commit()
            }
        }
        if ledger.active == nil { ledger.begin(start: start, end: end, speaker: speaker) }
        if let active = ledger.active { ledger.turns[active].segment.end = end }
        try await send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        turnBytes += pcm.count
    }
    public func commit() async throws {
        try check()
        guard ledger.active != nil else { return }
        // OpenAI requires at least 100ms in each committed buffer.
        if turnBytes < 4800 { try await send(["type": "input_audio_buffer.append", "audio": Data(count: 4800 - turnBytes).base64EncodedString()]) }
        ledger.commit(); turnBytes = 0
        try await send(["type": "input_audio_buffer.commit"])
    }
    public func finish() async throws -> [Segment] {
        do {
            try check(); try await commit()
            let deadline = ContinuousClock.now.advanced(by: .seconds(finishTimeout))
            while !ledger.isComplete {
                try check()
                guard ContinuousClock.now < deadline else { throw WhaleError("The last live transcript did not finish in time. Saved audio can be transcribed again.") }
                try await Task.sleep(for: .milliseconds(20))
            }
            let segments = ledger.segments
            await cancel(); return segments
        } catch { await cancel(); throw error }
    }
    public func cancel() async {
        closed = true; receiver?.cancel(); receiver = nil
        await transport.close()
    }
    private func send(_ event: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        let transport = self.transport
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await transport.send(data) }
                group.addTask {
                    try await Task.sleep(for: .seconds(10)); await transport.close()
                    throw WhaleError("The live transcription connection stopped responding.")
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: { Task { await transport.close() } }
    }
    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw WhaleError(failure) }
        guard !closed else { throw WhaleError("The live transcription connection closed.") }
    }
    private func receiveEvents() async {
        do {
            while !closed {
                let data = try await transport.receive()
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { continue }
                switch type {
                case "error", "conversation.item.input_audio_transcription.failed":
                    let message = (event["error"] as? [String: Any])?["message"] as? String
                    throw WhaleError(message ?? "OpenAI live transcription failed.")
                case "session.updated": ready = true
                case "input_audio_buffer.committed":
                    if let item = event["item_id"] as? String { try ledger.acknowledge(item) }
                case "conversation.item.input_audio_transcription.delta":
                    if let item = event["item_id"] as? String, let delta = event["delta"] as? String, !ledger.completed.contains(item) {
                        ledger.text[item, default: ""] += delta
                    }
                case "conversation.item.input_audio_transcription.completed":
                    if let item = event["item_id"] as? String, let text = event["transcript"] as? String {
                        ledger.text[item] = text; ledger.completed.insert(item)
                    }
                default: continue
                }
                await onUpdate(LiveTranscriptUpdate(segments: ledger.segments, interim: ledger.interim))
            }
        } catch { if !closed { failure = error.localizedDescription } }
    }
}
