import Foundation

public enum LiveRecordingTranscription {
    public static func run(audio: AsyncThrowingStream<LiveAudioPacket, Error>, apiKey: String,
                           labeler: LocalSpeakerLabeler,
                           onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void) async throws -> [Segment] {
        let client = LiveTranscriber(apiKey: apiKey, onUpdate: onUpdate)
        do {
            try await labeler.reset()
            try await client.start()
            var router = LiveTurnRouter()
            for try await packet in audio {
                try Task.checkCancellation()
                for chunk in try await labeler.append(packet) {
                    for routed in router.append(chunk) { try await forward(routed, to: client) }
                }
            }
            for chunk in try await labeler.finish() {
                for routed in router.append(chunk) { try await forward(routed, to: client) }
            }
            for chunk in router.finish() { try await forward(chunk, to: client) }
            return try await client.finish()
        } catch { await client.cancel(); throw error }
    }
    private static func forward(_ chunk: LabeledAudio, to client: LiveTranscriber) async throws {
        if let speaker = chunk.speaker {
            try await client.append(chunk.pcm, start: chunk.start, end: chunk.end, speaker: speaker)
        } else { try await client.commit() }
    }
}

/// A voice may need a few frames to become identifiable at speech onset. Hold at most
/// 300ms of that onset, rather than committing an isolated syllable to the recognizer.
/// Uncertainty between identified voices and overlapping speech remain explicit.
struct LiveTurnRouter {
    private var pending: LabeledAudio?
    private var previousSpeaker: String?
    mutating func append(_ chunk: LabeledAudio) -> [LabeledAudio] {
        if chunk.speaker == "Unassigned speaker", previousSpeaker == nil || pending != nil {
            if let previous = pending {
                pending = LabeledAudio(pcm: previous.pcm + chunk.pcm, start: previous.start, end: chunk.end, speaker: chunk.speaker)
            } else { pending = chunk }
            previousSpeaker = chunk.speaker
            if let pending, pending.end - pending.start > 0.3 { self.pending = nil; return [pending] }
            return []
        }
        previousSpeaker = chunk.speaker
        guard let pending else { return [chunk] }
        self.pending = nil
        if chunk.speaker?.hasPrefix("Speaker ") == true, abs(chunk.start - pending.end) < 0.001 {
            return [LabeledAudio(pcm: pending.pcm + chunk.pcm, start: pending.start, end: chunk.end, speaker: chunk.speaker)]
        }
        return [pending, chunk]
    }
    mutating func finish() -> [LabeledAudio] {
        defer { pending = nil }
        return pending.map { [$0] } ?? []
    }
}
