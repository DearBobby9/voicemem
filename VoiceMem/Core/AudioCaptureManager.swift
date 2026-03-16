import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioCapture")

// MARK: - Render-thread-safe callback box

/// A plain (non-actor) reference type that stores the audio buffer callback.
///
/// This box is the ONLY thing the AVAudioEngine tap closure captures. Because
/// the box itself carries no actor isolation, loading it from the audio render
/// thread does not trigger a `_dispatch_assert_queue_fail` assertion.
///
/// Thread-safety contract:
///   - `callback` is written once, from `@MainActor`, before `engine.start()`.
///   - After that it is read-only from the render thread.
///   - `nonisolated(unsafe)` opts out of Swift 6 Sendable checking for this
///     specific property. The manual contract above makes this sound.
private final class AudioCallbackBox {
    // Called on the audio render thread — NOT on MainActor.
    // Signature matches what the tap delivers: raw Float32 samples + wall-clock ms.
    nonisolated(unsafe) var callback: ((_ samples: UnsafeBufferPointer<Float>, _ frameCount: Int, _ timestampMs: Int64) -> Void)?
}

// MARK: - AudioCaptureManager

/// Captures audio from the default input device via AVAudioEngine.
///
/// Observable UI state (`isCapturing`, `currentDeviceName`, `sampleRate`) lives
/// on `@MainActor` for safe SwiftUI binding.
///
/// The real-time audio tap delivers samples via `audioStream`, an `AsyncStream`
/// whose `Continuation.yield()` is safe to call from any thread, including the
/// CoreAudio render thread. Consumers (e.g. `PipelineCoordinator`) `await` the
/// stream in a background `Task` — the render thread is never blocked.
@MainActor
@Observable
final class AudioCaptureManager {

    // MARK: Public observable state

    private(set) var isCapturing = false
    private(set) var currentDeviceName: String = "Unknown"
    private(set) var sampleRate: Double = 48_000

    // MARK: Audio stream

    /// Async stream of audio buffers emitted by the AVAudioEngine tap.
    ///
    /// Each element is a `(samples: [Float], timestampMs: Int64)` pair.
    /// The stream runs until `stop()` is called or the engine fails.
    /// Consumers must iterate on a background context — do NOT await on MainActor.
    private(set) var audioStream: AsyncStream<AudioBuffer>
    private var audioContinuation: AsyncStream<AudioBuffer>.Continuation

    // MARK: Private state

    private var engine: AVAudioEngine?
    private var configChangeObserver: (any NSObjectProtocol)?
    private let hardwareBufferSize: AVAudioFrameCount = 4096

    // MARK: Init

    init() {
        // Create the stream up-front so consumers can subscribe before start().
        // The stream is infinite; it ends when the continuation is finished.
        var cont: AsyncStream<AudioBuffer>.Continuation!
        let stream = AsyncStream<AudioBuffer>(bufferingPolicy: .bufferingNewest(16)) { cont = $0 }
        self.audioStream = stream
        self.audioContinuation = cont

        observeDeviceChanges()
        logger.info("[AudioCapture] Initialized")
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        sampleRate = hwFormat.sampleRate

        updateDeviceName()
        logger.info("[AudioCapture] Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Install tap via nonisolated static — closures created in @MainActor context
        // inherit @MainActor isolation in Swift 6, causing _dispatch_assert_queue_fail
        // when AVAudioEngine calls them on the render thread.
        let continuation = audioContinuation
        Self.installTap(on: inputNode, bufferSize: hardwareBufferSize, format: hwFormat, continuation: continuation)

        try engine.start()
        isCapturing = true
        logger.info("[AudioCapture] Started — \(self.currentDeviceName) @ \(self.sampleRate)Hz")
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isCapturing = false
        logger.info("[AudioCapture] Stopped")
        // Do NOT finish the continuation here — PipelineCoordinator may restart us.
        // The stream keeps running; no new yields arrive until next start().
    }

    func pause() {
        engine?.pause()
        isCapturing = false
        logger.info("[AudioCapture] Paused")
    }

    func resume() throws {
        if engine == nil {
            try start()
        } else {
            try engine?.start()
            isCapturing = true
            logger.info("[AudioCapture] Resumed")
        }
    }

    // MARK: - Device management

    private func updateDeviceName() {
        #if os(macOS)
        var deviceID: AudioDeviceID = 0
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &propertySize, &deviceID
        ) == noErr else { return }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
        }
        if status == noErr {
            currentDeviceName = cfName as String
        }
        #endif
    }

    // MARK: - Tap installation (nonisolated to prevent @MainActor closure inheritance)

    /// Closures created inside `@MainActor` methods inherit actor isolation in Swift 6.
    /// AVAudioEngine calls the tap block on the audio render thread → runtime asserts
    /// `_dispatch_assert_queue_fail`. By creating the closure in a `nonisolated static`
    /// context, it has NO actor isolation and runs safely on the render thread.
    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        continuation: AsyncStream<AudioBuffer>.Continuation
    ) {
        var tapCount = 0
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            // --- AUDIO RENDER THREAD (no actor isolation) ---
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1_000)

            tapCount += 1
            if tapCount <= 3 || tapCount % 500 == 0 {
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / max(1, Float(frameCount)))
                logger.info("[AudioCapture] Tap #\(tapCount): \(frameCount) frames, RMS=\(String(format: "%.6f", rms))")
            }

            continuation.yield(AudioBuffer(samples: samples, timestampMs: timestampMs))
        }
    }

    // MARK: - Device change observation

    private func observeDeviceChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                logger.info("[AudioCapture] Config changed — restarting")
                self.stop()
                do {
                    try self.start()
                } catch {
                    logger.error("[AudioCapture] Restart failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - AudioBuffer (value type crossing actor boundaries)

/// A single buffer of audio data produced by the tap and consumed by the pipeline.
/// `Sendable` because it contains only value types.
struct AudioBuffer: Sendable {
    let samples: [Float]       // PCM Float32, hardware sample rate, mono ch0
    let timestampMs: Int64     // Unix epoch ms at buffer capture time
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
