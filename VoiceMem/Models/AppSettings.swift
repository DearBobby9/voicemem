import Foundation

/// All user-configurable settings, backed by UserDefaults.
/// SwiftUI views bind to @AppStorage keys matching these names.
enum AppSettingsKey {
    // Recording
    static let autoStart = "autoStart"
    static let selectedMicrophone = "selectedMicrophone"

    // VAD
    static let vadThreshold = "vadThreshold"
    static let vadMinSpeechMs = "vadMinSpeechMs"
    static let vadMaxSegmentMs = "vadMaxSegmentMs"
    static let vadSilenceTriggerMs = "vadSilenceTriggerMs"

    // Transcription
    static let whisperModel = "whisperModel"
    static let transcriptionLanguage = "transcriptionLanguage"

    // Summary
    static let summaryIntervalMinutes = "summaryIntervalMinutes"
    static let summaryEngine = "summaryEngine"

    // Storage
    static let audioRetentionDays = "audioRetentionDays"

    // System
    static let launchAtLogin = "launchAtLogin"
    static let notifyOnTranscription = "notifyOnTranscription"
    static let globalHotkey = "globalHotkey"
}

/// Available WhisperKit models, from smallest to largest.
struct WhisperModel: Identifiable, Hashable {
    let id: String        // WhisperKit model identifier
    let displayName: String
    let size: String      // Human-readable size
    let languages: String // "English only" or "Multilingual"

    static let allModels: [WhisperModel] = [
        WhisperModel(id: "tiny.en", displayName: "Tiny (English)", size: "~39 MB", languages: "English only"),
        WhisperModel(id: "tiny", displayName: "Tiny", size: "~39 MB", languages: "Multilingual"),
        WhisperModel(id: "base.en", displayName: "Base (English)", size: "~74 MB", languages: "English only"),
        WhisperModel(id: "base", displayName: "Base", size: "~74 MB", languages: "Multilingual"),
        WhisperModel(id: "small.en", displayName: "Small (English)", size: "~244 MB", languages: "English only"),
        WhisperModel(id: "small", displayName: "Small", size: "~244 MB", languages: "Multilingual"),
        WhisperModel(id: "large-v3-v20240930_turbo", displayName: "Large v3 Turbo", size: "~632 MB", languages: "Multilingual"),
        WhisperModel(id: "large-v3", displayName: "Large v3", size: "~1.5 GB", languages: "Multilingual"),
    ]

    static let defaultModel = "large-v3-v20240930_turbo"
}

/// Summary engine options.
enum SummaryEngine: String, CaseIterable, Identifiable {
    case off = "off"
    case lmStudio = "lmstudio"
    case appleIntelligence = "apple"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "关闭"
        case .lmStudio: "LM Studio"
        case .appleIntelligence: "Apple Intelligence"
        }
    }

    var description: String {
        switch self {
        case .off: "仅拼接原文，无需额外资源"
        case .lmStudio: "调用 localhost:1234 本地 LLM"
        case .appleIntelligence: "macOS 26+ 内置模型，ANE 运行"
        }
    }
}

/// Transcription language preference.
enum TranscriptionLanguage: String, CaseIterable, Identifiable {
    case auto = "auto"
    case chinese = "zh"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "自动检测"
        case .chinese: "中文"
        case .english: "English"
        }
    }
}

/// Register UserDefaults defaults.
extension UserDefaults {
    static func registerVoiceMemDefaults() {
        standard.register(defaults: [
            AppSettingsKey.autoStart: true,
            AppSettingsKey.selectedMicrophone: "default",
            AppSettingsKey.vadThreshold: 0.5,
            AppSettingsKey.vadMinSpeechMs: 500,
            AppSettingsKey.vadMaxSegmentMs: 28000,
            AppSettingsKey.vadSilenceTriggerMs: 1500,
            AppSettingsKey.whisperModel: WhisperModel.defaultModel,
            AppSettingsKey.transcriptionLanguage: TranscriptionLanguage.auto.rawValue,
            AppSettingsKey.summaryIntervalMinutes: 15,
            AppSettingsKey.summaryEngine: SummaryEngine.off.rawValue,
            AppSettingsKey.audioRetentionDays: 7,
            AppSettingsKey.launchAtLogin: true,
            AppSettingsKey.notifyOnTranscription: false,
            AppSettingsKey.globalHotkey: "⌘⇧R",
        ])
    }
}
