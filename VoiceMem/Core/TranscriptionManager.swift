import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Transcription")

/// Thread-safe wrapper so WhisperKit can cross isolation boundaries in Swift 6.
private final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(_ kit: WhisperKit) { self.kit = kit }
}

/// Manages WhisperKit ASR — supports model selection, loading, and transcription.
@MainActor
@Observable
final class TranscriptionManager {
    private var whisperBox: WhisperKitBox?

    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var loadingProgress: String = ""
    private(set) var currentModelId: String = ""

    /// The model to load (read from UserDefaults).
    var selectedModelId: String {
        UserDefaults.standard.string(forKey: AppSettingsKey.whisperModel) ?? WhisperModel.defaultModel
    }

    /// Language preference for transcription.
    var languagePreference: String? {
        let pref = UserDefaults.standard.string(forKey: AppSettingsKey.transcriptionLanguage) ?? "auto"
        return pref == "auto" ? nil : pref
    }

    init() {
        logger.info("[Transcription] Initialized")
    }

    // MARK: - Model Lifecycle

    /// Load (or switch) the WhisperKit model. Downloads on first use.
    func loadModel(modelId: String? = nil) async throws {
        let targetModel = modelId ?? selectedModelId

        // Skip if already loaded with this model
        if isModelLoaded && currentModelId == targetModel { return }

        // Unload previous model if switching
        if isModelLoaded {
            whisperBox = nil
            isModelLoaded = false
            logger.info("[Transcription] Unloaded previous model \(self.currentModelId)")
        }

        isLoading = true
        loadingProgress = "正在下载模型..."
        defer { isLoading = false; loadingProgress = "" }

        logger.info("[Transcription] Loading model \(targetModel)...")

        // Explicitly request ANE for both encoder and decoder
        let computeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        let config = WhisperKitConfig(
            model: targetModel,
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .none
        )

        loadingProgress = "正在初始化 WhisperKit..."
        let kit = try await WhisperKit(config)
        whisperBox = WhisperKitBox(kit)
        currentModelId = targetModel

        // Persist the choice
        UserDefaults.standard.set(targetModel, forKey: AppSettingsKey.whisperModel)

        isModelLoaded = true
        logger.info("[Transcription] Model \(targetModel) loaded successfully")
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
        let model = currentModelId
        let lang = languagePreference

        logger.info("[Transcription] Transcribing \(segment.durationMs)ms, model=\(model), lang=\(lang ?? "auto")")

        let (text, detectedLang) = try await Task.detached(priority: .userInitiated) {
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
            language: detectedLang,
            audioPath: audioPath.lastPathComponent,
            model: model,
            confidence: nil
        )
    }

    // MARK: - Available Models

    /// List all available models with their metadata.
    static let availableModels = WhisperModel.allModels
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
