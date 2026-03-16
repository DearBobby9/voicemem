import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")

/// Captures audio from the microphone via AVAudioEngine.
/// Taps at hardware native format, converts to 16kHz mono via DispatchQueue
/// (off the realtime audio thread to avoid render graph crashes).
@MainActor
@Observable
final class AudioCaptureManager {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configChangeObserver: (any NSObjectProtocol)?
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1
    private let bufferSize: AVAudioFrameCount = 4096
    /// Serial queue for audio conversion (off the realtime render thread)
    private let conversionQueue = DispatchQueue(label: "com.voicemem.audioconversion", qos: .userInitiated)

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

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            logger.error("[AudioCapture] Failed to create audio converter")
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = conv

        updateDeviceName()

        // Capture everything needed by the tap closure
        let callback = self.onAudioBuffer
        let audioConverter = conv
        let targetRate = targetSampleRate
        let queue = conversionQueue

        // Tap at hardware native format — then bounce to conversionQueue for resampling
        // (AVAudioConverter must NOT run on the realtime audio render thread)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { buffer, _ in
            // Copy buffer data immediately on the audio thread (cheap memcpy)
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let sampleRate = buffer.format.sampleRate
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Convert on a non-realtime queue
            queue.async {
                let ratio = targetRate / sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)

                guard let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ),
                let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)),
                let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioConverter.outputFormat, frameCapacity: outputFrameCount)
                else { return }

                // Fill input buffer
                inputBuffer.frameLength = AVAudioFrameCount(frameCount)
                rawSamples.withUnsafeBufferPointer { src in
                    inputBuffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
                }

                var inputProvided = false
                var error: NSError?
                let status = audioConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    if inputProvided {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputProvided = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                guard status == .haveData || status == .endOfStream,
                      error == nil,
                      let outData = outputBuffer.floatChannelData,
                      outputBuffer.frameLength > 0 else { return }

                let convertedCount = Int(outputBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: outData[0], count: convertedCount))

                callback?(samples, timestampMs)
            }
        }

        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Started: \(self.currentDeviceName), \(hwFormat.sampleRate)Hz → \(self.targetSampleRate)Hz mono")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
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
    case converterCreationFailed
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: "Failed to create audio format (16kHz mono)"
        case .converterCreationFailed: "Failed to create audio format converter"
        case .engineStartFailed: "Failed to start audio engine"
        }
    }
}
