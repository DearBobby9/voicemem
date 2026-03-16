import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "VAD")

/// Voice Activity Detection using Silero VAD CoreML model.
/// Detects speech segments and emits AudioSegment when speech ends.
/// @MainActor: observable state read by SwiftUI, audio buffers dispatched here from audio thread.
@MainActor
@Observable
final class VADManager {
    /// Silero VAD threshold — higher = fewer false positives
    var threshold: Float = 0.5

    /// Minimum speech duration to emit (ms)
    var minSpeechMs: Int64 = 500

    /// Maximum segment duration before forced cut (ms)
    var maxSegmentMs: Int64 = 28_000

    /// Silence duration after speech to trigger segment end (ms)
    var silenceTriggerMs: Int64 = 1500

    private(set) var isSpeechDetected = false

    /// Emitted when a complete speech segment is detected.
    var onSpeechSegment: ((_ segment: AudioSegment) -> Void)?

    // Internal state
    private var speechStartTimestamp: Int64?
    private var accumulatedSamples: [Float] = []
    private var lastSpeechTimestamp: Int64 = 0
    private var frameCounter: Int = 0

    // Silero VAD model state
    // TODO: Replace with actual Silero VAD CoreML inference when FluidAudio is integrated
    // For MVP development/testing, uses energy-based detection as a placeholder

    init() {
        logger.info("[VAD] Initialized with threshold=\(self.threshold)")
    }

    // MARK: - Process Audio

    /// Process a buffer of PCM Float32 samples (16kHz mono).
    /// Called by AudioCaptureManager on each buffer.
    func process(samples: [Float], timestamp: Int64) {
        frameCounter += 1

        // Run VAD inference
        let speechProbability = detectSpeech(samples: samples)
        let isSpeech = speechProbability >= threshold

        if isSpeech {
            handleSpeechDetected(samples: samples, timestamp: timestamp)
        } else {
            handleSilenceDetected(samples: samples, timestamp: timestamp)
        }
    }

    // MARK: - Speech State Machine

    private func handleSpeechDetected(samples: [Float], timestamp: Int64) {
        if speechStartTimestamp == nil {
            // Speech just started
            speechStartTimestamp = timestamp
            accumulatedSamples = []
            isSpeechDetected = true
            logger.info("[VAD] Speech started at \(timestamp)")
        }

        accumulatedSamples.append(contentsOf: samples)
        lastSpeechTimestamp = timestamp

        // Check max segment duration
        if let start = speechStartTimestamp, (timestamp - start) >= maxSegmentMs {
            logger.info("[VAD] Max segment duration reached, forcing cut")
            emitSegment(endTimestamp: timestamp)
        }
    }

    private func handleSilenceDetected(samples: [Float], timestamp: Int64) {
        guard speechStartTimestamp != nil else { return }

        // S1: Keep accumulating during silence grace period to avoid clipping final word
        accumulatedSamples.append(contentsOf: samples)

        // Check if silence has lasted long enough to trigger segment end
        if (timestamp - lastSpeechTimestamp) >= silenceTriggerMs {
            emitSegment(endTimestamp: timestamp)
        }
    }

    private func emitSegment(endTimestamp: Int64) {
        guard let start = speechStartTimestamp else { return }

        let durationMs = endTimestamp - start
        guard durationMs >= minSpeechMs else {
            logger.info("[VAD] Discarded short segment: \(durationMs)ms")
            resetState()
            return
        }

        let segment = AudioSegment(
            samples: accumulatedSamples,
            timestampStart: start,
            timestampEnd: endTimestamp
        )

        logger.info("[VAD] Emitted segment: \(durationMs)ms, \(segment.samples.count) samples")
        onSpeechSegment?(segment)
        resetState()
    }

    private func resetState() {
        speechStartTimestamp = nil
        accumulatedSamples = []
        isSpeechDetected = false
    }

    // MARK: - VAD Inference

    /// Detect speech probability in a buffer.
    /// TODO: Replace with Silero VAD CoreML model inference.
    /// Current implementation: energy-based placeholder for development.
    private func detectSpeech(samples: [Float]) -> Float {
        // Placeholder: RMS energy-based detection
        // Will be replaced by Silero VAD CoreML when FluidAudio is integrated
        guard !samples.isEmpty else { return 0 }

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))

        // Map RMS to probability-like value (rough heuristic)
        // RMS > 0.02 is typically speech, < 0.005 is silence
        let probability = min(1.0, max(0.0, (rms - 0.005) / 0.02))
        return probability
    }
}
