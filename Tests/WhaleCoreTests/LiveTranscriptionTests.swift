import XCTest
import AVFoundation
@testable import WhaleCore

final class LiveTranscriptionTests: XCTestCase {
    func testLiveAudioEmitsDuringCaptureAndFlushesTailWithDifferentRates() throws {
        var packets: [LiveAudioPacket] = []
        let processor = try LiveAudioProcessor { packets.append($0) }
        for tick in 0..<20 {
            for (track, rate) in [(AudioTrackWriter.Track.microphone, 48000.0), (.system, 44100.0)] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))!
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.1) }
                try processor.append(buffer, track: track, at: 100 + Double(tick) / 10)
            }
        }
        XCTAssertGreaterThan(packets.count, 0, "Audio must stream before Stop, not batch after recording")
        try processor.finish()
        XCTAssertEqual(packets.last!.end, 2, accuracy: 0.01)
        XCTAssertEqual(packets.reduce(0) { $0 + $1.pcm.count }, 2 * 24000 * 2, accuracy: 100)
        for pair in zip(packets, packets.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001) }
        XCTAssertTrue(packets.contains { $0.pcm.contains(where: { $0 != 0 }) })
    }
    func testLiveCompletionFlagSurvivesPersistence() throws {
        var meeting = Meeting(title: "Partial", segments: [Segment(start: 0, end: 1, speaker: "Microphone", text: "Saved")])
        meeting.liveTranscriptComplete = false
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(decoded.liveTranscriptComplete, false)
        XCTAssertEqual(decoded.segments, meeting.segments)
    }
}

extension LiveTranscriptionTests {
    func testOutOfOrderCompletionsUseAcknowledgedAudioTurns() throws {
        var ledger = LiveTranscript()
        ledger.begin(start: 0, end: 1, speaker: "Speaker 1"); ledger.commit()
        ledger.begin(start: 2, end: 3, speaker: "Speaker 2"); ledger.commit()
        ledger.text["second"] = "Second"; ledger.completed.insert("second")
        XCTAssertTrue(ledger.segments.isEmpty)
        try ledger.acknowledge("first"); try ledger.acknowledge("second")
        ledger.text["first"] = "First"; ledger.completed.insert("first")
        XCTAssertEqual(ledger.segments.map(\.text), ["First", "Second"])
        XCTAssertEqual(ledger.segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(ledger.segments.map(\.start), [0, 2])
        let ids = ledger.segments.map(\.id)
        try ledger.acknowledge("first")
        XCTAssertEqual(ledger.segments.map(\.id), ids)
        XCTAssertTrue(ledger.isComplete)
    }
    func testUnacknowledgedDraftCannotInventSpeakerAttribution() {
        var ledger = LiveTranscript()
        ledger.begin(start: 0, end: 1, speaker: "Speaker 1")
        ledger.text["draft"] = "Hello"
        XCTAssertTrue(ledger.segments.isEmpty)
        XCTAssertEqual(ledger.interim.first?.speaker, "Speaker 1")
        ledger.commit()
        XCTAssertEqual(ledger.interim.first?.speaker, "Identifying speaker…")
        XCTAssertFalse(ledger.isComplete)
    }
    func testSpeakerChangeCommitsSeparateAudioTurnsAndFlushesTail() async throws {
        let socket = MockLiveSocket()
        let client = LiveTranscriber(transport: socket) { _ in }
        try await client.start()
        try await client.append(Data(count: 9600), start: 0, end: 0.2, speaker: "Speaker 1")
        try await client.append(Data(count: 9600), start: 0.2, end: 0.4, speaker: "Speaker 2")
        let segments = try await client.finish()
        XCTAssertEqual(segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(segments.map(\.start), [0, 0.2])
    }
    func testServiceFailureDoesNotReportCompleteTranscript() async throws {
        let socket = MockLiveSocket(failOnAppend: true)
        let client = LiveTranscriber(transport: socket) { _ in }
        try await client.start()
        do {
            try await client.append(Data(count: 9600), start: 0, end: 0.2, speaker: "Speaker 1")
            _ = try await client.finish(); XCTFail("Connection loss must retain saved audio for recovery")
        } catch { await client.cancel() }
    }
    func testMissingCompletionTimesOutRatherThanSavingPartialAsComplete() async throws {
        let socket = MockLiveSocket(omitCompletion: true)
        let client = LiveTranscriber(transport: socket, finishTimeout: 0.1) { _ in }
        try await client.start()
        try await client.append(Data(count: 9600), start: 0, end: 0.2, speaker: "Speaker 1")
        do { _ = try await client.finish(); XCTFail("Incomplete stream must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not finish")) }
    }
}

private actor MockLiveSocket: LiveTranscriptionTransport {
    var queue: [Data] = []
    var waiter: CheckedContinuation<Data, Error>?
    var closed = false
    var turns = 0
    let failOnAppend: Bool
    let omitCompletion: Bool
    init(failOnAppend: Bool = false, omitCompletion: Bool = false) {
        self.failOnAppend = failOnAppend; self.omitCompletion = omitCompletion
    }
    func send(_ data: Data) async throws {
        let event = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        switch event["type"] as? String {
        case "session.update": try emit(["type": "session.updated"])
        case "input_audio_buffer.append": if failOnAppend { throw WhaleError("Simulated connection loss") }
        case "input_audio_buffer.commit":
            turns += 1
            let item = "turn-\(turns)"
            // Exercise completion arriving before its commit acknowledgement.
            if !omitCompletion { try emit(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "transcript": "Hello \(turns)"]) }
            try emit(["type": "input_audio_buffer.committed", "item_id": item])
        default: break
        }
    }
    func emit(_ event: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { queue.append(data) }
    }
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
}

extension LiveTranscriptionTests {
    func testShortUncertainOnsetJoinsItsIdentifiedVoiceWithoutDroppingAudio() {
        var router = LiveTurnRouter()
        let onset = LabeledAudio(pcm: Data([1, 2]), start: 0, end: 0.1, speaker: "Unassigned speaker")
        XCTAssertTrue(router.append(onset).isEmpty)
        let routed = router.append(LabeledAudio(pcm: Data([3, 4]), start: 0.1, end: 0.3, speaker: "Speaker 2"))
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first?.pcm, Data([1, 2, 3, 4]))
        XCTAssertEqual(routed.first?.start, 0)
        XCTAssertEqual(routed.first?.speaker, "Speaker 2")
        XCTAssertEqual(router.append(LabeledAudio(pcm: Data([5, 6]), start: 0.3, end: 0.4, speaker: "Unassigned speaker")).first?.speaker, "Unassigned speaker")
    }
    func testUnresolvedOnsetIsFlushedAtStopAndNeverLabeledAsOverlapParticipant() {
        var router = LiveTurnRouter()
        let onset = LabeledAudio(pcm: Data([1, 2]), start: 0, end: 0.1, speaker: "Unassigned speaker")
        _ = router.append(onset)
        let overlap = router.append(LabeledAudio(pcm: Data([3, 4]), start: 0.1, end: 0.3, speaker: "Overlapping speakers"))
        XCTAssertEqual(overlap.map(\.speaker), ["Unassigned speaker", "Overlapping speakers"])
        var tail = LiveTurnRouter()
        _ = tail.append(onset)
        XCTAssertEqual(tail.finish().first?.pcm, onset.pcm)
        XCTAssertTrue(tail.finish().isEmpty)
    }
}
