import AVFoundation

/// A serial-queue-owned writer shared by two independently clocked audio sources.
public final class AudioTrackWriter {
    public enum Track: String { case microphone, system }
    private let folder: URL
    private var epoch: Double?
    private var files: [Track: AVAudioFile] = [:]

    public init(folder: URL, epoch: Double? = nil) { self.folder = folder; self.epoch = epoch }

    public func write(_ buffer: AVAudioPCMBuffer, track: Track, at time: Double) throws {
        guard time.isFinite, buffer.frameLength > 0 else { return }
        let format = buffer.format
        let file: AVAudioFile
        if let existing = files[track] {
            guard existing.processingFormat == format else {
                throw WhaleError("The audio device format changed. Saved audio is retained; start a new recording for the new device.")
            }
            file = existing
        } else {
            file = try AVAudioFile(forWriting: folder.appendingPathComponent(track.rawValue + ".caf"), settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            files[track] = file
        }
        // Both sources use the host clock. Pad delayed starts and missing samples.
        if epoch == nil { epoch = time }
        let expected = AVAudioFramePosition(max(0, time - (epoch ?? time)) * format.sampleRate)
        var missing = expected - file.framePosition
        if missing > AVAudioFramePosition(format.sampleRate * 0.02) {
            guard missing < AVAudioFramePosition(format.sampleRate * 30) else {
                throw WhaleError("Audio was interrupted for more than 30 seconds. The recording has been saved.")
            }
            while missing > 0 {
                let size = AVAudioFrameCount(min(missing, 8192))
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else {
                    throw WhaleError("Could not allocate an audio buffer.")
                }
                silence.frameLength = size
                for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
                }
                try file.write(from: silence)
                missing -= AVAudioFramePosition(size)
            }
        }
        try file.write(from: buffer)
    }

    public func finish() -> String? {
        let mic = (files[.microphone]?.length ?? 0) > 0
        let system = (files[.system]?.length ?? 0) > 0
        files.removeAll()
        if !mic && !system { return "No audio samples were saved. Check Whale's Microphone and System Audio Recording permissions." }
        if !mic { return "No microphone audio was received. Mac audio is saved; check the microphone before your next meeting." }
        if !system { return "No Mac audio was received. Your microphone is saved; check system-audio permissions and that the meeting was playing audio." }
        return nil
    }

    /// Audio callbacks lend their memory only until they return. Own a copy before dispatching to disk.
    public static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let outputs = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard inputs.count == outputs.count else { return nil }
        for (input, output) in zip(inputs, outputs) {
            guard input.mDataByteSize <= output.mDataByteSize, let from = input.mData, let to = output.mData else { return nil }
            memcpy(to, from, Int(input.mDataByteSize))
        }
        return destination
    }
}
