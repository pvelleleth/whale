import Foundation
import FluidAudio

struct LabeledAudio: Sendable {
    let pcm: Data
    let start: Double
    let end: Double
    let speaker: String?
}

/// The actor owns CoreML's mutable streaming state; inference never runs on the UI/capture queue.
public actor LocalSpeakerLabeler {
    private var diarizer: LSEENDDiarizer?
    private var audio = Data()
    private var consumedSamples = 0
    private var receivedSamples = 0

    public init() {}
    public func prepare() async throws {
        if diarizer != nil { return }
        let model = try await LSEENDModel.loadFromHuggingFace(variant: .dihard3, stepSize: .step100ms, computeUnits: .cpuOnly)
        diarizer = try LSEENDDiarizer(model: model)
    }
    public func reset() throws {
        guard let diarizer else { throw WhaleError("The local speaker model is not ready.") }
        diarizer.reset(); audio.removeAll(keepingCapacity: true)
        consumedSamples = 0; receivedSamples = 0
    }
    func append(_ packet: LiveAudioPacket) throws -> [LabeledAudio] {
        guard let diarizer else { throw WhaleError("The local speaker model is not ready.") }
        guard abs(packet.start - Double(receivedSamples) / 24000) < 0.02 else {
            throw WhaleError("The live audio clock was interrupted.")
        }
        audio.append(packet.pcm); receivedSamples += packet.pcm.count / 2
        let samples = Self.decode(packet.pcm)
        let update = try diarizer.process(samples: samples, sourceSampleRate: 24000)
        return try consume(update?.chunkResult)
    }
    func finish() throws -> [LabeledAudio] {
        guard let diarizer else { throw WhaleError("The local speaker model is not ready.") }
        var result = try consume(diarizer.finalizeSession()?.chunkResult)
        // A sub-frame tail still belongs to the recording. Never silently drop it.
        if !audio.isEmpty {
            result.append(LabeledAudio(pcm: audio, start: Double(consumedSamples) / 24000,
                end: Double(receivedSamples) / 24000, speaker: Self.isAudible(audio) ? "Unassigned speaker" : nil))
            audio.removeAll()
        }
        return result
    }
    private func consume(_ chunk: DiarizerChunkResult?) throws -> [LabeledAudio] {
        guard let chunk, let diarizer, let hz = diarizer.modelFrameHz, let speakers = diarizer.numSpeakers else { return [] }
        var result: [LabeledAudio] = []
        for frame in 0..<chunk.finalizedFrameCount {
            let endSample = min(receivedSamples, Int((Double(chunk.startFrame + frame + 1) * 24000 / hz).rounded()))
            let count = endSample - consumedSamples
            guard count > 0 else { continue }
            guard count * 2 <= audio.count else { throw WhaleError("Local speaker timing exceeded the audio buffer.") }
            let pcm = Data(audio.prefix(count * 2)); audio.removeFirst(count * 2)
            let active = (0..<speakers).filter { chunk.probability(speaker: $0, frame: frame, numSpeakers: speakers) >= 0.5 }
            let label: String?
            if active.count == 1 { label = "Speaker \(active[0] + 1)" }
            else if active.count > 1 { label = "Overlapping speakers" }
            else {
                label = Self.isAudible(pcm) ? "Unassigned speaker" : nil
            }
            let start = Double(consumedSamples) / 24000
            consumedSamples = endSample
            if let last = result.last, last.speaker == label {
                result[result.count - 1] = LabeledAudio(pcm: last.pcm + pcm, start: last.start, end: Double(endSample) / 24000, speaker: label)
            } else {
                result.append(LabeledAudio(pcm: pcm, start: start, end: Double(endSample) / 24000, speaker: label))
            }
        }
        return result
    }
    private static func isAudible(_ data: Data) -> Bool {
        let samples = decode(data)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
        return rms > 0.003
    }
    private static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }
}
