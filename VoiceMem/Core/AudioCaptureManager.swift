import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")

/// Captures audio from the microphone via AVAudioEngine at 16kHz mono.
/// Uses a mixer node to resample from hardware rate (e.g. 48kHz) to 16kHz.
/// Forwards PCM Float32 buffers to a callback for VAD processing.
@MainActor
@Observable
final class AudioCaptureManager {
    private var engine: AVAudioEngine?
    private var mixerNode: AVAudioMixerNode?
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
        let hwFormat = inputNode.outputFormat(forBus: 0)

        logger.info("[AudioCapture] Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        // Insert a mixer node between input and output to handle resampling.
        // AVAudioEngine resamples automatically when connecting nodes with different formats.
        let mixer = AVAudioMixerNode()
        self.mixerNode = mixer
        engine.attach(mixer)

        // input (hwFormat) → mixer → mainMixer
        engine.connect(inputNode, to: mixer, format: hwFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: targetFormat)

        // Mute output to prevent feedback
        engine.mainMixerNode.outputVolume = 0

        updateDeviceName()

        // Install tap on mixer node at target format (16kHz mono)
        mixer.installTap(onBus: 0, bufferSize: bufferSize, format: targetFormat) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

            self.onAudioBuffer?(samples, timestampMs)
        }

        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Started: \(self.currentDeviceName), \(hwFormat.sampleRate)Hz → \(self.targetSampleRate)Hz mono")
    }

    func stop() {
        mixerNode?.removeTap(onBus: 0)
        engine?.stop()
        if let mixer = mixerNode {
            engine?.detach(mixer)
        }
        engine = nil
        mixerNode = nil
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

    private func updateDeviceName() {
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
        guard status == noErr else { return }

        var nameSize: UInt32 = 0
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Get size first
        AudioObjectGetPropertyDataSize(deviceID, &nameAddress, 0, nil, &nameSize)
        guard nameSize > 0 else { return }

        var name: CFString = "" as CFString
        let nameStatus = withUnsafeMutablePointer(to: &name) { ptr in
            var size = UInt32(MemoryLayout<CFString>.size)
            return AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, ptr)
        }
        if nameStatus == noErr {
            currentDeviceName = name as String
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
