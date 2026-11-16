import XCTest
import AVFoundation
import Security
@testable import WhaleCore

/// Opt-in on-device smoke test. Only synthesized fixture audio is sent to the API.
final class LiveIntegrationTests: XCTestCase {
    func testLocalModelAndOpenAILiveStream() async throws {
        guard ProcessInfo.processInfo.environment["WHALE_LIVE_TEST"] == "1" else { throw XCTSkip("Set WHALE_LIVE_TEST=1 and WHALE_TEST_AUDIO to a synthetic WAV fixture") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WHALE_TEST_AUDIO"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 24000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        var pcm = Data()
        for i in 0..<Int(buffer.frameLength) {
            var value = Int16((max(-1, min(1, samples[i])) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let labeler = LocalSpeakerLabeler()
        let loadStart = Date()
        try await labeler.prepare()
        print("BENCH model_load_seconds=\(Date().timeIntervalSince(loadStart))")
        try await labeler.reset()
        var labels: [String: Double] = [:]
        let inferStart = Date()
        for offset in stride(from: 0, to: pcm.count, by: 9600) {
            let end = min(pcm.count, offset + 9600)
            for chunk in try await labeler.append(LiveAudioPacket(pcm: pcm.subdata(in: offset..<end), start: Double(offset) / 48000, end: Double(end) / 48000)) {
                labels[chunk.speaker ?? "Silence", default: 0] += chunk.end - chunk.start
            }
        }
        let flushStart = Date()
        _ = try await labeler.finish()
        let inferElapsed = Date().timeIntervalSince(inferStart)
        let seconds = Double(pcm.count) / 48000
        print("BENCH audio_seconds=\(seconds) inference_seconds=\(inferElapsed) local_flush_seconds=\(Date().timeIntervalSince(flushStart)) labels=\(labels)")
        XCTAssertLessThan(inferElapsed, seconds, "Local diarization must keep up with capture")
        XCTAssertGreaterThanOrEqual(labels.keys.filter { $0.hasPrefix("Speaker ") }.count, 2, "Two synthesized voices should produce two identities")
        if ProcessInfo.processInfo.environment["WHALE_LOCAL_ONLY"] == "1" { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.whale.openai", kSecAttrAccount as String: "api-key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw WhaleError("Test cannot read Whale's OpenAI key (status \(status))") }
        let pair = AsyncThrowingStream<LiveAudioPacket, Error>.makeStream()
        let metrics = LiveTestMetrics()
        let task = Task { try await LiveRecordingTranscription.run(audio: pair.stream, apiKey: key, labeler: labeler) { update in await metrics.record(update) } }
        let processor = try LiveAudioProcessor { pair.continuation.yield($0) }
        for offset in stride(from: 0, to: Int(buffer.frameLength), by: 4800) {
            let count = min(4800, Int(buffer.frameLength) - offset)
            let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            input.frameLength = AVAudioFrameCount(count)
            input.floatChannelData![0].update(from: samples.advanced(by: offset), count: count)
            try processor.append(input, track: .system, at: 100 + Double(offset) / 24000)
            try await Task.sleep(for: .milliseconds(200))
        }
        let stop = Date()
        try processor.finish()
        pair.continuation.finish()
        let transcript = try await task.value
        let elapsed = Date().timeIntervalSince(stop)
        let beforeStop = await metrics.firstTextDate
        print("BENCH stop_to_transcript_seconds=\(elapsed) text_before_stop=\(beforeStop.map { $0 < stop } ?? false)")
        for segment in transcript { print("SYNTHETIC \(segment.start)-\(segment.end) \(segment.speaker): \(segment.text)") }
        XCTAssertFalse(transcript.isEmpty)
        let text = transcript.map(\.text).joined(separator: " ").lowercased()
        for word in ["friday", "testing", "results"] { XCTAssertTrue(text.contains(word), "Missing expected fixture word: \(word)") }
        XCTAssertTrue(beforeStop.map { $0 < stop } ?? false)
        XCTAssertGreaterThanOrEqual(Set(transcript.map(\.speaker).filter { $0.hasPrefix("Speaker ") }).count, 2)
    }
}
private actor LiveTestMetrics {
    var firstTextDate: Date?
    func record(_ update: LiveTranscriptUpdate) {
        if firstTextDate == nil && (!update.segments.isEmpty || !update.interim.isEmpty) { firstTextDate = Date() }
    }
}
