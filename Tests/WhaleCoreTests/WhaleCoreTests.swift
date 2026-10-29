import XCTest
import AVFoundation
@testable import WhaleCore

final class WhaleCoreTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WhaleTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    func testPersistenceSearchAndSpeakerRenameStayConsistent() throws {
        let folder = try temporaryFolder()
        var meeting = Meeting(title: "Product review", segments: [Segment(start: 1, end: 4, speaker: "A", text: "The release needs accessibility fixes.")])
        do {
            let store = try MeetingStore(root: folder)
            try store.save(meeting)
            XCTAssertEqual(try store.load(query: "accessibility").map(\.id), [meeting.id])
            meeting.speakerNames["A"] = "Priya"
            meeting.segments[0].text = "The release is approved."
            try store.save(meeting)
            XCTAssertTrue(try store.load(query: "accessibility").isEmpty)
            XCTAssertEqual(try store.load(query: "Priya approved").count, 1)
            XCTAssertNoThrow(try store.load(query: "\" OR * NOT ("))
        }
        let reopened = try MeetingStore(root: folder)
        XCTAssertEqual(try reopened.load().first?.segments, meeting.segments)
        XCTAssertEqual(try reopened.load().first?.speakerNames["A"], "Priya")
        let audioFolder = try reopened.folder(for: meeting.id)
        try Data([1, 2, 3]).write(to: audioFolder.appendingPathComponent("test.caf"))
        try reopened.delete(meeting.id)
        XCTAssertTrue(try reopened.load(query: "Priya").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioFolder.path))
    }
    func testRecoveryPreservesTranscriptAndMarksOnlyUnfinishedJobs() throws {
        let store = try MeetingStore(root: temporaryFolder())
        let segment = Segment(start: 10, end: 12, speaker: "B", text: "Keep this checkpoint")
        let unfinished = Meeting(title: "Interrupted", status: .processing, segments: [segment])
        let ready = Meeting(title: "Done", status: .ready)
        try store.save(unfinished); try store.save(ready)
        try store.recoverInterrupted()
        let items = try store.load()
        XCTAssertEqual(items.first(where: { $0.id == unfinished.id })?.status, .interrupted)
        XCTAssertEqual(items.first(where: { $0.id == unfinished.id })?.segments, [segment])
        XCTAssertEqual(items.first(where: { $0.id == ready.id })?.status, .ready)
    }
    func testTranscriptOffsetsAndIndependentSpeakerLabels() throws {
        let json = Data(#"{"segments":[{"start":1.5,"end":3,"speaker":"A","text":" Hello "},{"start":4,"end":2,"speaker":"A","text":"Invalid"}]}"#.utf8)
        let segments = try AIClient.decodeTranscript(json, offset: 1200, part: 1, multipleParts: true)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 1201.5)
        XCTAssertEqual(segments[0].speaker, "Part 2 · Speaker A")
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertThrowsError(try AIClient.decodeTranscript(Data(#"{"text":"missing speakers"}"#.utf8), offset: 0, part: 0, multipleParts: false))
    }
    func testSummaryReadsMessageOutputAfterReasoningAndRejectsIncomplete() throws {
        let json = Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"A useful summary"}]}]}"#.utf8)
        XCTAssertEqual(try AIClient.decodeSummary(json), "A useful summary")
        XCTAssertThrowsError(try AIClient.decodeSummary(Data(#"{"status":"incomplete","output":[]}"#.utf8)))
    }
    func testAudioMixPreservesDurationAndResumesFromManifest() async throws {
        let folder = try temporaryFolder()
        for (name, sampleRate) in [("microphone.caf", 48_000.0), ("system.caf", 44_100.0)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 2))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / sampleRate) * 0.1) }
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
        let parts = try await AudioPreparation.prepare(folder: folder)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].duration, 2, accuracy: 0.1)
        let exported = AVURLAsset(url: folder.appendingPathComponent(parts[0].filename))
        let duration = try await exported.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        // A retry reuses completed exports rather than requiring the original files again.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("microphone.caf"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("system.caf"))
        let resumed = try await AudioPreparation.prepare(folder: folder)
        XCTAssertEqual(resumed[0].filename, parts[0].filename)
    }
    func testEmptyAudioFailsWithoutCreatingFakeTranscript() async throws {
        let folder = try temporaryFolder()
        do { _ = try await AudioPreparation.prepare(folder: folder); XCTFail("Expected empty audio failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No usable audio")) }
    }
    func testAudioOnlyTracksAlignToSharedClockAndPreserveDelayedStart() throws {
        let folder = try temporaryFolder()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.25 }
        let writer = AudioTrackWriter(folder: folder)
        // A permission prompt can take any length of time; first audio sets the origin.
        try writer.write(buffer, track: .microphone, at: 500)
        try writer.write(buffer, track: .system, at: 502)
        XCTAssertNil(writer.finish())
        let mic = try AVAudioFile(forReading: folder.appendingPathComponent("microphone.caf"))
        let system = try AVAudioFile(forReading: folder.appendingPathComponent("system.caf"))
        XCTAssertEqual(mic.length, 16_000)
        XCTAssertEqual(system.length, 48_000)
        let samples = AVAudioPCMBuffer(pcmFormat: system.processingFormat, frameCapacity: 48_000)!
        try system.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][0], 0)
        XCTAssertEqual(samples.floatChannelData![0][31_999], 0)
        XCTAssertEqual(samples.floatChannelData![0][32_000], 0.25)
    }

    func testBorrowedAudioBufferIsCopiedBeforeCallbackReturns() throws {
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            source.frameLength = 32
            for buffer in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                memset(buffer.mData!, 0x12, Int(buffer.mDataByteSize))
            }
            let copy = try XCTUnwrap(AudioTrackWriter.copy(source))
            for buffer in UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList) {
                memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
            }
            XCTAssertEqual(copy.frameLength, 32)
            for buffer in UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList) {
                XCTAssertEqual(buffer.mData!.load(as: UInt8.self), 0x12)
            }
        }
    }

    func testCaptureWriterRejectsChangedFormatsAndLongGaps() throws {
        let writer = AudioTrackWriter(folder: try temporaryFolder(), epoch: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        memset(buffer.floatChannelData![0], 0, 160 * MemoryLayout<Float>.size)
        try writer.write(buffer, track: .microphone, at: 0)
        XCTAssertThrowsError(try writer.write(buffer, track: .microphone, at: 40))
        let changed = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let changedBuffer = AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 480)!
        changedBuffer.frameLength = 480
        XCTAssertThrowsError(try writer.write(changedBuffer, track: .microphone, at: 0.01))
        XCTAssertTrue(writer.finish()?.contains("No Mac audio") == true)
    }

    func testGeneratedTitlePersistsAndUpdatesSearchWithoutReplacingManualTitle() throws {
        let folder = try temporaryFolder()
        let store = try MeetingStore(root: folder)
        var meeting = Meeting(title: "Meeting · Oct 29, 2026 at 10:00 AM")
        meeting.titleSource = .placeholder
        try store.save(meeting)
        meeting.applyGeneratedTitle("Website Launch Planning")
        try store.save(meeting)
        XCTAssertEqual(try store.load(query: "Website Launch").first?.id, meeting.id)
        XCTAssertEqual(try store.load().first?.titleSource, .generated)
        XCTAssertFalse(meeting.needsAutomaticTitle)
        XCTAssertTrue(try store.load(query: "10:00").isEmpty)
        meeting.title = "My custom name"; meeting.titleSource = .manual
        meeting.applyGeneratedTitle("A replacement that should not apply")
        XCTAssertEqual(meeting.title, "My custom name")
        meeting.applyGeneratedTitle("Explicitly requested replacement", replacingExisting: true)
        XCTAssertEqual(meeting.title, "Explicitly requested replacement")
        XCTAssertEqual(meeting.titleSource, .generated)
    }

    func testLegacyTitleMetadataDecodesAndPreservesExistingCustomNames() throws {
        for title in ["Meeting · Oct 29, 2026 at 10:00 AM", "Customer onboarding"] {
            let meeting = Meeting(title: title)
            var oldPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
            oldPayload.removeValue(forKey: "titleSource")
            var decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: oldPayload))
            XCTAssertNil(decoded.titleSource)
            decoded.applyGeneratedTitle("AI suggested title")
            XCTAssertEqual(decoded.title, title.hasPrefix("Meeting · ") ? "AI suggested title" : title)
        }
    }

    func testGeneratedTitlesAreCleanAndBounded() throws {
        XCTAssertEqual(try AIClient.validatedTitle("  “Website   Launch Planning” \n"), "Website Launch Planning")
        XCTAssertThrowsError(try AIClient.validatedTitle("   \n"))
        XCTAssertThrowsError(try AIClient.validatedTitle(String(repeating: "a", count: 81)))
        XCTAssertThrowsError(try AIClient.validatedTitle("# Not a plain title"))
        XCTAssertEqual(try AIClient.validatedTitle("Brief conversation"), "Brief conversation")
    }

}
