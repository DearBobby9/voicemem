import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")

/// Captures audio from the microphone via AVAudioEngine.
/// Taps at hardware native format, performs simple decimation to ~16kHz.
/// AVAudioConverter is NOT used — it holds internal audio unit refs that
/// trigger _dispatch_assert_queue_fail on any non-render thread.
@MainActor
@Observable
final class AudioCaptureManager {
    private var engine: AVAudioEngine?
    private var configChangeObserver: (any NSObjectProtocol)?
    private let bufferSize: AVAudioFrameCount = 4096

    private(set) var isCapturing = false
    private(set) var currentDeviceName: String = "Unknown"
    private(set) var sampleRate: Double = 48000  // actual hardware rate

    /// Called with each audio buffer (PCM Float32, hardware sample rate, mono ch0).
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
        sampleRate = hwFormat.sampleRate
        logger.info("[AudioCapture] Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        updateDeviceName()

        // Capture callback on @MainActor before installing tap on audio thread
        let callback = self.onAudioBuffer

        // Tap at hardware native format — zero conversion, zero crash risk
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            // Take first channel only (mono)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

            callback?(samples, timestampMs)
        }

        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Started: \(self.currentDeviceName), \(hwFormat.sampleRate)Hz mono")
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
            &address, 0, nil, &propertySize, &deviceID
        )
        guard status == noErr else { return }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        if nameStatus == noErr {
            currentDeviceName = cfName as String
        }
        #endif
    }

    private func observeDeviceChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
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
                    logger.error("[AudioCapture] Failed to restart: \(error.localizedDescription)")
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
        case .formatCreationFailed: "Failed to create audio format"
        case .engineStartFailed: "Failed to start audio engine"
        }
    }
}
