import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Transcription")

/// Thread-safe wrapper so WhisperKit can cross isolation boundaries in Swift 6.
private final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

/// Manages WhisperKit ASR model — loads once, transcribes audio segments on demand.
@MainActor
@Observable
final class TranscriptionManager {
    private var whisperBox: WhisperKitBox?
    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var modelName = "large-v3-v20240930_turbo"

    init() {
        logger.info("[Transcription] Initialized, model=\(self.modelName)")
    }

    // MARK: - Model Lifecycle

    /// Load WhisperKit model. First run downloads ~632MB and compiles for ANE.
    func loadModel() async throws {
        guard !isModelLoaded else { return }
        isLoading = true
        defer { isLoading = false }

        logger.info("[Transcription] Loading model \(self.modelName)...")

        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            logLevel: .none
        )
        let kit = try await WhisperKit(config)
        whisperBox = WhisperKitBox(kit)

        isModelLoaded = true
        logger.info("[Transcription] Model loaded successfully")
    }

    // MARK: - Transcribe

    /// Transcribe an audio segment via its saved WAV file.
    func transcribe(segment: AudioSegment) async throws -> Transcription {
        guard let box = whisperBox, isModelLoaded else {
            throw TranscriptionError.modelNotLoaded
        }

        let audioPath = AudioEncoder.fullPath(for: segment)
        let path = audioPath.path
        let segStart = segment.timestampStart
        let segEnd = segment.timestampEnd
        let model = modelName

        logger.info("[Transcription] Transcribing \(segment.durationMs)ms from \(audioPath.lastPathComponent)...")

        // Run transcription off MainActor to avoid blocking UI
        let (text, language) = try await Task.detached(priority: .userInitiated) {
            let results = try await box.kit.transcribe(audioPath: path)
            let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let language = results.first?.language
            return (text, language)
        }.value

        logger.info("[Transcription] Result (\(text.count) chars): \(text.prefix(80))...")

        return Transcription(
            text: text,
            timestampStart: segStart,
            timestampEnd: segEnd,
            language: language,
            audioPath: audioPath.lastPathComponent,
            model: model,
            confidence: nil
        )
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "WhisperKit model not loaded"
        case .transcriptionFailed(let reason): "Transcription failed: \(reason)"
        }
    }
}
