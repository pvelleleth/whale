import Foundation

public struct Segment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public init(id: UUID = UUID(), start: Double, end: Double, speaker: String, text: String) {
        self.id = id; self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, recorded, processing, ready, failed, interrupted
    public var label: String { rawValue.capitalized }
}

public enum MeetingTitleSource: String, Codable, Sendable { case placeholder, generated, manual }

public struct Meeting: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var titleSource: MeetingTitleSource?
    public var date: Date
    public var duration: Double
    public var status: MeetingStatus
    public var segments: [Segment]
    public var speakerNames: [String: String]
    public var summary: String
    public var error: String?
    /// nil: file transcription; false: live transcript may be incomplete; true: both streams drained.
    public var liveTranscriptComplete: Bool?
    public init(id: UUID = UUID(), title: String, date: Date = Date(), duration: Double = 0,
                status: MeetingStatus = .recorded, segments: [Segment] = [], summary: String = "") {
        self.id = id; self.title = title; self.date = date; self.duration = duration
        self.status = status; self.segments = segments; self.speakerNames = [:]; self.summary = summary
    }
    // Missing metadata remains compatible with libraries created before automatic titles.
    public var needsAutomaticTitle: Bool {
        titleSource == .placeholder || (titleSource == nil && title.hasPrefix("Meeting · "))
    }
    public mutating func applyGeneratedTitle(_ proposed: String, replacingExisting: Bool = false) {
        guard needsAutomaticTitle || replacingExisting else { return }
        title = proposed; titleSource = .generated
    }
    public func name(for speaker: String) -> String { speakerNames[speaker] ?? speaker }
    public var searchableText: String {
        ([title, summary] + segments.map { name(for: $0.speaker) + " " + $0.text }).joined(separator: "\n")
    }
    public var markdown: String {
        "# \(title)\n\n\(date.formatted())\n\n## Summary\n\n\(summary)\n\n## Transcript\n\n" +
        segments.map { "**\(timestamp($0.start)) · \(name(for: $0.speaker))**\n\n\($0.text)" }.joined(separator: "\n\n")
    }
}

public func timestamp(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}

public struct WhaleError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
