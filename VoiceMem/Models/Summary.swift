import Foundation
import GRDB

/// A 15-minute aggregation block (Dayflow-style).
/// `rawText` is always populated (concatenated transcriptions).
/// `summaryText` is filled by an LLM plugin (nullable for MVP).
struct Summary: Codable, Identifiable, Sendable {
    var id: Int64?
    let windowStart: Int64         // 15-min window start, Unix epoch ms
    let windowEnd: Int64           // 15-min window end, Unix epoch ms
    let rawText: String            // Concatenated transcriptions (MVP)
    var summaryText: String?       // AI summary (Plugin fills this)
    let transcriptionCount: Int
    var model: String?             // Model used for summary (null = pure aggregation)
    let createdAt: Int64           // Unix epoch ms

    /// The text to display — prefer AI summary, fall back to raw.
    var displayText: String {
        summaryText ?? rawText
    }

    init(
        id: Int64? = nil,
        windowStart: Int64,
        windowEnd: Int64,
        rawText: String,
        summaryText: String? = nil,
        transcriptionCount: Int,
        model: String? = nil
    ) {
        self.id = id
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.rawText = rawText
        self.summaryText = summaryText
        self.transcriptionCount = transcriptionCount
        self.model = model
        self.createdAt = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - GRDB

extension Summary: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "summaries"

    enum Columns: String, ColumnExpression {
        case id, windowStart, windowEnd, rawText, summaryText
        case transcriptionCount, model, createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
