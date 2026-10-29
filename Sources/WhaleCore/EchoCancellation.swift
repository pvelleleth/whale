import AVFoundation
import WhaleAEC

/// Offline AEC3. The originals are read-only; only derived files are replaced.
public enum EchoCancellation {
    public static let revision = "aec3-v1"
    public static let cleanedFilename = "microphone-aec3-v1.caf"

    public static func clean(folder: URL) throws -> String {
        let micURL = folder.appendingPathComponent("microphone.caf")
        let systemURL = folder.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: micURL.path),
              FileManager.default.fileExists(atPath: systemURL.path) else { return "microphone.caf" }
        let scratch = folder.appendingPathComponent(".echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let mic = try normalize(micURL, to: scratch.appendingPathComponent("mic.caf"))
        let reference = try normalize(systemURL, to: scratch.appendingPathComponent("reference.caf"))
        guard mic.length > 0, reference.length > 0 else { return "microphone.caf" }
        guard let processor = whale_aec_create() else { throw WhaleError("Could not initialize echo cancellation. Original recordings are safe.") }
        defer { whale_aec_destroy(processor) }
        let format = mic.processingFormat
        let capture = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        let render = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        let temp = scratch.appendingPathComponent("clean.caf")
        // Close the writer before publishing its completed file.
        do {
            let writer = try AVAudioFile(forWriting: temp, settings: format.settings)
            defer { writer.close() }
            while mic.framePosition < mic.length {
                try Task.checkCancellation()
                try readFrame(mic, into: capture)
                let count = capture.frameLength
                guard count > 0 else { break }
                // Pad the last frame and any reference tail; never truncate the mic.
                let c = capture.floatChannelData![0]
                for i in Int(count)..<480 { c[i] = 0 }
                let r = render.floatChannelData![0]
                r.initialize(repeating: 0, count: 480)
                if reference.framePosition < reference.length { try readFrame(reference, into: render) }
                let code = whale_aec_process(processor, r, c, output.floatChannelData![0])
                guard code == 0 else { throw WhaleError("Echo cancellation failed (WebRTC \(code)). Original recordings are safe.") }
                output.frameLength = count
                for i in 0..<Int(count) where !output.floatChannelData![0][i].isFinite {
                    throw WhaleError("Echo cancellation produced invalid audio. Original recordings are safe.")
                }
                try writer.write(from: output)
            }
        }
        try Task.checkCancellation()
        let destination = folder.appendingPathComponent(cleanedFilename)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else { try FileManager.default.moveItem(at: temp, to: destination) }
        return cleanedFilename
    }

    // AVAudioFile reads may return fewer frames than requested before EOF.
    private static func readFrame(_ file: AVAudioFile, into destination: AVAudioPCMBuffer) throws {
        let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        var count: AVAudioFrameCount = 0
        while count < 480 && file.framePosition < file.length {
            try file.read(into: scratch, frameCount: 480 - count)
            guard scratch.frameLength > 0 else { throw WhaleError("Could not read the complete recording for echo cancellation.") }
            destination.floatChannelData![0].advanced(by: Int(count)).update(from: scratch.floatChannelData![0], count: Int(scratch.frameLength))
            count += scratch.frameLength
        }
        destination.frameLength = count
    }

    /// Streaming conversion keeps memory bounded even for multi-hour meetings.
    private static func normalize(_ source: URL, to destination: URL) throws -> AVAudioFile {
        let input = try AVAudioFile(forReading: source)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw WhaleError("Could not convert the recording for echo cancellation.")
        }
        converter.downmix = true
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        do {
            let writer = try AVAudioFile(forWriting: destination, settings: format.settings)
            defer { writer.close() }
            var ended = false
            while !ended {
                try Task.checkCancellation()
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: output, error: &conversionError) { requested, state in
                    if input.framePosition >= input.length { state.pointee = .endOfStream; return nil }
                    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: requested)!
                    do { try input.read(into: buffer, frameCount: requested) }
                    catch { readError = error; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return buffer
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                guard status != .error else { throw WhaleError("Audio conversion failed during echo cancellation.") }
                if output.frameLength > 0 { try writer.write(from: output) }
                ended = status == .endOfStream
            }
        }
        return try AVAudioFile(forReading: destination)
    }
}
