import XCTest
import AVFoundation
@testable import WhaleCore

final class EchoCancellationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WhaleAEC-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ samples: [Float], to url: URL, rate: Double = 48_000) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for i in samples.indices { buffer.floatChannelData![0][i] = samples[i] }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw WhaleError("Unexpected EOF in test audio") }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
    private func power(_ data: [Float], _ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + Double(data[$1]) * Double(data[$1]) } / Double(range.count)
    }
    // A known delayed, reverberant reference plus an independent local voice-like
    // signal lets us measure suppression and retention, not merely successful export.
    func testDelayedEchoSuppressionAndDoubleTalkPreservation() throws {
        let root = try folder(), rate = 48_000, count = 30 * 48_000 + 137
        var seed: UInt64 = 17
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Double(seed >> 32) / Double(UInt32.max) * 2 - 1)
        }
        var render = [Float](repeating: 0, count: count)
        var near = render, mic = render
        var a: Float = 0, b: Float = 0
        for i in 0..<count {
            a = 0.85 * a + 0.15 * noise()
            b = 0.75 * b + 0.25 * noise()
            let t = Double(i) / Double(rate)
            if t < 20 { render[i] = a * 0.6 * Float(0.6 + 0.4 * sin(t * 7)) }
            if t >= 10 { near[i] = b * 0.4 * Float(0.7 + 0.3 * sin(t * 11)) }
            mic[i] = near[i]
            if i >= 3840 { mic[i] += render[i - 3840] * 0.65 }
            if i >= 4800 { mic[i] += render[i - 4800] * 0.2 }
        }
        let micURL = root.appendingPathComponent("microphone.caf")
        let renderURL = root.appendingPathComponent("system.caf")
        try write(mic, to: micURL); try write(render, to: renderURL)
        let originalMic = try Data(contentsOf: micURL), originalRender = try Data(contentsOf: renderURL)
        let cleaned = try read(root.appendingPathComponent(EchoCancellation.clean(folder: root)))
        XCTAssertEqual(cleaned.count, mic.count)
        XCTAssertTrue(cleaned.allSatisfy(\.isFinite))
        XCTAssertEqual(try Data(contentsOf: micURL), originalMic)
        XCTAssertEqual(try Data(contentsOf: renderURL), originalRender)
        let echoRange = (6 * rate)..<(9 * rate)
        let reduction = 10 * log10(power(mic, echoRange) / max(1e-15, power(cleaned, echoRange)))
        print("AEC echo reduction: \(reduction) dB")
        XCTAssertGreaterThan(reduction, 10)
        // Allow the small filter-bank latency when measuring retained local speech.
        for range in [(14 * rate)..<(18 * rate), (24 * rate)..<(28 * rate)] {
            var bestCorrelation = 0.0
            var bestLag = 0
            for lag in 0...960 {
                var dot = 0.0, nearEnergy = 0.0, outEnergy = 0.0
                for i in stride(from: range.lowerBound, to: range.upperBound, by: 16) {
                    let x = Double(near[i]), y = Double(cleaned[i + lag])
                    dot += x * y; nearEnergy += x * x; outEnergy += y * y
                }
                let correlation = dot / sqrt(max(1e-20, nearEnergy * outEnergy))
                if correlation > bestCorrelation { bestCorrelation = correlation; bestLag = lag }
            }
            print("AEC local signal correlation: \(bestCorrelation), lag: \(bestLag)")
            XCTAssertGreaterThan(bestCorrelation, 0.7)
            XCTAssertGreaterThan(power(cleaned, range) / power(near, range), 0.3)
        }
    }
    func testMissingReferenceKeepsMicrophoneAndSilentReferenceKeepsTail() throws {
        let root = try folder()
        let mic = (0..<96017).map { Float(sin(Double($0) * 0.06) * 0.1) }
        try write(mic, to: root.appendingPathComponent("microphone.caf"))
        XCTAssertEqual(try EchoCancellation.clean(folder: root), "microphone.caf")
        try write([Float](repeating: 0, count: 44_100), to: root.appendingPathComponent("system.caf"), rate: 44_100)
        let cleaned = try read(root.appendingPathComponent(EchoCancellation.clean(folder: root)))
        XCTAssertEqual(cleaned.count, mic.count)
        XCTAssertGreaterThan(power(cleaned, 60_000..<90_000), 0.002)
    }
    func testLegacyExportsAreNotReusedForCleanedTranscription() async throws {
        let root = try folder()
        try write([Float](repeating: 0.01, count: 48_000), to: root.appendingPathComponent("microphone.caf"))
        try Data([1]).write(to: root.appendingPathComponent("part-0.m4a"))
        try JSONEncoder().encode([AudioPart(filename: "part-0.m4a", offset: 0, duration: 1)])
            .write(to: root.appendingPathComponent("parts.json"))
        let parts = try await AudioPreparation.prepare(folder: root)
        XCTAssertTrue(parts[0].filename.hasPrefix(EchoCancellation.revision))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("microphone.caf").path))
    }
    func testCancellationDoesNotPublishCleanedFileOrTouchOriginals() async throws {
        let root = try folder()
        try write([Float](repeating: 0.01, count: 48_000), to: root.appendingPathComponent("microphone.caf"))
        try write([Float](repeating: 0.02, count: 48_000), to: root.appendingPathComponent("system.caf"))
        let original = try Data(contentsOf: root.appendingPathComponent("microphone.caf"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try EchoCancellation.clean(folder: root)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("microphone.caf")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(EchoCancellation.cleanedFilename).path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".echo-") })
    }
}
