import AVFoundation
import WhaleAEC

public struct LiveAudioPacket: Sendable {
    public let pcm: Data
    public let start: Double
    public let end: Double
}

/// Owned by the capture writer's serial queue. Retains at most a short alignment window.
/// Normalizes both sources to the same clock before running the existing AEC3 processor.
public final class LiveAudioProcessor {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var converters: [AudioTrackWriter.Track: AVAudioConverter] = [:]
    private var nextInput: [AudioTrackWriter.Track: Int] = [:]
    private var frames: [AudioTrackWriter.Track: [Int: [Float]]] = [:]
    private var epoch: Double?
    private var latest = 0
    private var cursor = 0
    private var packetStart = 0
    private var microphone: [Float] = []
    private var system: [Float] = []
    private let aec: UnsafeMutableRawPointer
    private let encoder = PCMEncoder()
    private let emit: (LiveAudioPacket) throws -> Void

    public init(emit: @escaping (LiveAudioPacket) throws -> Void) throws {
        guard let aec = whale_aec_create() else { throw WhaleError("Could not initialize live echo reduction.") }
        self.aec = aec; self.emit = emit
    }
    deinit { whale_aec_destroy(aec) }

    public func append(_ input: AVAudioPCMBuffer, track: AudioTrackWriter.Track, at time: Double) throws {
        guard input.frameLength > 0, time.isFinite else { return }
        if epoch == nil { epoch = time }
        let converter: AVAudioConverter
        if let existing = converters[track] {
            guard existing.inputFormat == input.format else { throw WhaleError("The live audio format changed.") }
            converter = existing
        } else {
            guard let created = AVAudioConverter(from: input.format, to: format) else { throw WhaleError("Could not convert live audio.") }
            created.downmix = true; created.primeMethod = .none
            converters[track] = created; converter = created
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 48000 / input.format.sampleRate)) + 32
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard result != .error else { throw WhaleError("Live audio conversion failed.") }
        let expected = max(0, Int(((time - (epoch ?? time)) * 48000).rounded()))
        var position = nextInput[track] ?? expected
        if expected - position > 960 { position = expected }
        guard position >= cursor else { throw WhaleError("Live audio arrived too late to align. The original audio is still being recorded.") }
        guard position - cursor < 48000 * 5 else { throw WhaleError("Live audio was interrupted.") }
        let count = Int(output.frameLength)
        let samples = output.floatChannelData![0]
        var consumed = 0
        while consumed < count {
            let block = position / 480
            let within = position % 480
            let amount = min(480 - within, count - consumed)
            var values = frames[track]?[block] ?? [Float](repeating: 0, count: 480)
            for i in 0..<amount {
                let sample = samples[consumed + i]
                values[within + i] = sample.isFinite ? sample : 0
            }
            frames[track, default: [:]][block] = values
            position += amount; consumed += amount
        }
        nextInput[track] = position
        latest = max(latest, position)
        // Allow 500ms for independently scheduled hardware callbacks, including a silent source.
        try drain(until: max(0, latest - 24000))
    }
    public func finish() throws {
        try drain(until: ((latest + 479) / 480) * 480)
        try emitPacket()
    }
    private func drain(until limit: Int) throws {
        while cursor + 480 <= limit {
            let block = cursor / 480
            let capture = frames[.microphone]?.removeValue(forKey: block) ?? [Float](repeating: 0, count: 480)
            let render = frames[.system]?.removeValue(forKey: block) ?? [Float](repeating: 0, count: 480)
            var cleaned = [Float](repeating: 0, count: 480)
            guard whale_aec_process(aec, render, capture, &cleaned) == 0 else { throw WhaleError("Live echo reduction failed.") }
            let count = min(480, max(0, latest - cursor))
            microphone.append(contentsOf: cleaned.prefix(count)); system.append(contentsOf: render.prefix(count))
            cursor += 480
            if microphone.count >= 9600 { try emitPacket() }
        }
    }
    private func emitPacket() throws {
        guard !microphone.isEmpty else { return }
        let count = microphone.count
        let mixed = zip(microphone, system).map { max(-1, min(1, ($0 + $1) * 0.75)) }
        let packet = LiveAudioPacket(pcm: try encoder.encode(mixed),
            start: Double(packetStart) / 48000, end: Double(packetStart + count) / 48000)
        try emit(packet)
        packetStart += count; microphone.removeAll(keepingCapacity: true); system.removeAll(keepingCapacity: true)
    }
}

/// Causal FIR decimation keeps a continuous sample clock without dropping a converter tail
/// at every packet boundary. The 63-tap low-pass removes frequencies above the 12kHz Nyquist limit.
private final class PCMEncoder {
    private static let taps: [Float] = {
        let count = 63
        let cutoff = 0.22
        var values = (0..<count).map { i -> Double in
            let x = Double(i - count / 2)
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(count - 1)))
        }
        let sum = values.reduce(0, +)
        values = values.map { $0 / sum }
        return values.map(Float.init)
    }()
    private var history = [Float](repeating: 0, count: 63)
    private var cursor = 0
    private var phase = 0
    func encode(_ samples: [Float]) throws -> Data {
        var output = Data(capacity: samples.count)
        for sample in samples {
            history[cursor] = sample
            cursor = (cursor + 1) % history.count
            phase += 1
            if phase == 2 {
                phase = 0
                var value: Float = 0
                for i in 0..<history.count { value += history[(cursor + i) % history.count] * Self.taps[i] }
                var integer = Int16((max(-1, min(1, value)) * 32767).rounded()).littleEndian
                withUnsafeBytes(of: &integer) { output.append(contentsOf: $0) }
            }
        }
        return output
    }
}
