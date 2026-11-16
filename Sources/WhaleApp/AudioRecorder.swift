import AVFoundation
import CoreAudio
import WhaleCore

/// Audio-only: a Core Audio process tap plus AVAudioEngine. No display capture session exists.
final class AudioRecorder: @unchecked Sendable {
    private let writerQueue = DispatchQueue(label: "app.whale.audio-writer", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "app.whale.system-audio", qos: .userInteractive)
    private let pendingBuffers = DispatchSemaphore(value: 128)
    // Hardware resources are created and destroyed on the main actor.
    private var engine: AVAudioEngine?
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var configurationObserver: NSObjectProtocol?
    private var microphoneTapInstalled = false
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    // Writer state is accessed only on writerQueue.
    private var writer: AudioTrackWriter?
    private var liveProcessor: LiveAudioProcessor?
    private var liveContinuation: AsyncThrowingStream<LiveAudioPacket, Error>.Continuation?
    private var failure: String?
    private var accepting = false
    var onFailure: (@Sendable (String) -> Void)?

    @MainActor
    func start(folder: URL, liveAudio: AsyncThrowingStream<LiveAudioPacket, Error>.Continuation? = nil) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw WhaleError("Microphone access is off. Enable Whale in System Settings → Privacy & Security → Microphone.")
        }
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            let microphoneFormat = input.outputFormat(forBus: 0)
            guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 else {
                throw WhaleError("No microphone is available. Select an input device in System Settings → Sound.")
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: microphoneFormat) { [weak self] buffer, time in
                let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                self?.enqueue(buffer, track: .microphone, at: AVAudioTime.seconds(forHostTime: hostTime))
            }
            microphoneTapInstalled = true
            engine.prepare()
            let format = try createSystemTap()
            // Use the first audio timestamp as the common origin, after any permission prompt.
            writerQueue.sync {
                writer = AudioTrackWriter(folder: folder)
                failure = nil; accepting = true
                liveContinuation = liveAudio
                if let liveAudio {
                    do {
                        liveProcessor = try LiveAudioProcessor { packet in
                            switch liveAudio.yield(packet) {
                            case .enqueued: break
                            case .dropped: throw WhaleError("Live transcription could not keep up with the recording. Saved audio is available for recovery.")
                            case .terminated: throw CancellationError()
                            @unknown default: throw CancellationError()
                            }
                        }
                    } catch { liveAudio.finish(throwing: error); liveContinuation = nil }
                }
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, systemQueue) { [weak self] _, inputData, inputTime, _, _ in
                guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
                let timestamp = inputTime.pointee
                let hostTime = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
                self.enqueue(buffer, track: .system, at: AVAudioTime.seconds(forHostTime: hostTime))
            }, "Create the system audio reader")
            try check(AudioDeviceStart(aggregateID, ioProc), "Start system audio recording. Allow Whale's System Audio Recording permission in System Settings")
            try engine.start()
            // Register after start: setup notifications are not interruptions.
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.writerQueue.async { self.fail("The audio device configuration changed. Saved audio is retained; start a new recording for the current device.") }
            }
            let formatListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.writerQueue.async { self.fail("The system audio format changed. Saved audio is retained; start a new recording.") }
            }
            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, systemQueue, formatListener), "Monitor the system audio format")
            tapFormatListener = formatListener
            if let failure = writerQueue.sync(execute: { self.failure }) { throw WhaleError(failure) }
        } catch {
            tearDownHardware()
            writerQueue.sync { accepting = false; _ = writer?.finish(); writer = nil; liveProcessor = nil; liveContinuation?.finish(throwing: error); liveContinuation = nil }
            throw error
        }
    }

    @MainActor
    private func createSystemTap() throws -> AVAudioFormat {
        var pid = ProcessInfo.processInfo.processIdentifier
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess), "Identify Whale's audio process")
        guard ownProcess != kAudioObjectUnknown else { throw WhaleError("Could not identify Whale's audio process. Try recording again.") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = "Whale meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create the system audio tap")
        var streamDescription = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioTapPropertyFormat
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription), "Read the system audio format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { throw WhaleError("Unsupported system audio format.") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Whale Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Do not block start until another application plays audio.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create the audio-only capture device")
        return format
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, track: AudioTrackWriter.Track, at time: Double) {
        guard buffer.frameLength > 0 else { return }
        guard pendingBuffers.wait(timeout: .now()) == .success else {
            writerQueue.async { self.fail("The disk could not keep up with audio capture. Saved audio is retained.") }
            return
        }
        guard let owned = AudioTrackWriter.copy(buffer) else {
            pendingBuffers.signal()
            writerQueue.async { self.fail("Could not copy a captured audio buffer.") }
            return
        }
        writerQueue.async {
            defer { self.pendingBuffers.signal() }
            guard self.accepting else { return }
            do { try self.writer?.write(owned, track: track, at: time) }
            catch { self.fail(error.localizedDescription) }
            do { try self.liveProcessor?.append(owned, track: track, at: time) }
            catch {
                self.liveProcessor = nil
                self.liveContinuation?.finish(throwing: error); self.liveContinuation = nil
            }
        }
    }

    private func fail(_ message: String) {
        guard accepting, failure == nil else { return }
        failure = message; accepting = false
        onFailure?(message)
    }

    @MainActor
    @discardableResult
    func stop() async -> String? {
        // Quiesce callbacks before draining the writer queue and closing files.
        tearDownHardware()
        return await withCheckedContinuation { continuation in
            writerQueue.async {
                self.accepting = false
                let warning = self.writer?.finish()
                self.writer = nil
                do { try self.liveProcessor?.finish(); self.liveContinuation?.finish() }
                catch { self.liveContinuation?.finish(throwing: error) }
                self.liveProcessor = nil; self.liveContinuation = nil
                continuation.resume(returning: self.failure ?? warning)
            }
        }
    }

    @MainActor
    private func tearDownHardware() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver); self.configurationObserver = nil }
        if let engine {
            engine.stop()
            if microphoneTapInstalled { engine.inputNode.removeTap(onBus: 0); microphoneTapInstalled = false }
            self.engine = nil
        }
        if let tapFormatListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, systemQueue, tapFormatListener)
            self.tapFormatListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
                self.ioProc = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw WhaleError("\(action) failed (Core Audio \(status)).") }
    }
}
