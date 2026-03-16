import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")

/// Captures audio from the microphone via AVAudioEngine at 16kHz mono.
/// Forwards PCM Float32 buffers to a callback for VAD processing.
/// @MainActor: observable state read by SwiftUI; audio tap dispatches to main.
@MainActor
@Observable
final class AudioCaptureManager {
    private var engine: AVAudioEngine?
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private let bufferSize: AVAudioFrameCount = 4096

    private(set) var isCapturing = false
    private(set) var currentDeviceName: String = "Unknown"

    /// Called with each audio buffer (PCM Float32, 16kHz mono).
    var onAudioBuffer: ((_ samples: [Float], _ timestamp: Int64) -> Void)?

    init() {
        observeDeviceChanges()
    }

    // MARK: - Start / Stop

    func start() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode

        // Request 16kHz mono — AVAudioEngine converts from hardware rate automatically
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            logger.error("[AudioCapture] Failed to create target audio format")
            throw AudioCaptureError.formatCreationFailed
        }

        updateDeviceName(inputNode: inputNode)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            guard let self, let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

            self.onAudioBuffer?(samples, timestampMs)
        }

        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Started capturing from \(self.currentDeviceName) at \(self.targetSampleRate)Hz mono")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isCapturing = false
        logger.info("[AudioCapture] Stopped")
    }

    func pause() {
        engine?.pause()
        isCapturing = false
        logger.info("[AudioCapture] Paused")
    }

    func resume() throws {
        guard let engine else {
            try start()
            return
        }
        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Resumed")
    }

    // MARK: - Device Management

    private func updateDeviceName(inputNode: AVAudioInputNode) {
        // Try to get the device name from the input node's audio unit
        #if os(macOS)
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize,
            &deviceID
        )
        if status == noErr {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            if nameStatus == noErr, let cfName = name?.takeUnretainedValue() {
                currentDeviceName = cfName as String
            }
        }
        #endif
    }

    private func observeDeviceChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                logger.info("[AudioCapture] Audio configuration changed, restarting...")
                self.stop()
                do {
                    try self.start()
                } catch {
                    logger.error("[AudioCapture] Failed to restart after config change: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case formatCreationFailed
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: "Failed to create audio format (16kHz mono)"
        case .engineStartFailed: "Failed to start audio engine"
        }
    }
}
