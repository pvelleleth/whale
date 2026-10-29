import AVFoundation

public struct AudioPart: Codable, Sendable {
    public let filename: String
    public let offset: Double
    public let duration: Double
}

/// Resumable audio preparation; raw CAF tracks remain available after every failure.
public enum AudioPreparation {
    public static func prepare(folder: URL) async throws -> [AudioPart] {
        let manifest = folder.appendingPathComponent("parts.json")
        if let data = try? Data(contentsOf: manifest), let parts = try? JSONDecoder().decode([AudioPart].self, from: data),
           !parts.isEmpty, parts.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.filename).path) }) {
            return parts
        }
        let composition = AVMutableComposition()
        var inputs: [AVMutableAudioMixInputParameters] = []
        for name in ["microphone.caf", "system.caf"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let source = tracks.first else { continue }
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0, let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
            let volume = AVMutableAudioMixInputParameters(track: track)
            volume.setVolume(0.75, at: .zero)
            inputs.append(volume)
        }
        let duration = composition.duration.seconds
        guard duration.isFinite, duration > 0.25 else { throw WhaleError("No usable audio was captured. Check microphone and System Audio Recording permissions.") }
        let mix = AVMutableAudioMix(); mix.inputParameters = inputs
        var parts: [AudioPart] = []
        var offset = 0.0
        while offset < duration {
            try Task.checkCancellation()
            var length = min(1200, duration - offset)
            let filename = "part-\(parts.count).m4a"
            let url = folder.appendingPathComponent(filename)
            while true {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                    throw WhaleError("Could not create the audio encoder.")
                }
                exporter.audioMix = mix
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 48_000), duration: CMTime(seconds: length, preferredTimescale: 48_000))
                try await exporter.export(to: url, as: .m4a)
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                if size < 24_000_000 { break }
                guard length > 10 else { throw WhaleError("Could not compress this recording below the upload limit.") }
                length /= 2
            }
            parts.append(AudioPart(filename: filename, offset: offset, duration: length))
            offset += length
        }
        try JSONEncoder().encode(parts).write(to: manifest, options: .atomic)
        return parts
    }
}
