import Foundation
import GRDB

/// A single VAD-detected speech segment transcribed by WhisperKit.
struct Transcription: Codable, Identifiable, Sendable {
    var id: Int64?
    let text: String
    let timestampStart: Int64      // Unix epoch ms
    let timestampEnd: Int64        // Unix epoch ms
    let durationMs: Int64
    let language: String?
    let audioPath: String?         // Relative to Application Support/VoiceMem/audio/
    let model: String
    let confidence: Double?
    let createdAt: Int64           // Unix epoch ms

    init(
        id: Int64? = nil,
        text: String,
        timestampStart: Int64,
        timestampEnd: Int64,
        language: String? = nil,
        audioPath: String? = nil,
        model: String = "whisperkit",
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.timestampStart = timestampStart
        self.timestampEnd = timestampEnd
        self.durationMs = timestampEnd - timestampStart
        self.language = language
        self.audioPath = audioPath
        self.model = model
        self.confidence = confidence
        self.createdAt = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - GRDB

extension Transcription: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcriptions"

    enum Columns: String, ColumnExpression {
        case id, text, timestampStart, timestampEnd, durationMs
        case language, audioPath, model, confidence, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
