import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Database")

/// Manages SQLite database via GRDB — transcriptions, summaries, FTS5.
final class DatabaseManager: Sendable {
    let dbQueue: DatabaseQueue

    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceMem", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("voicemem.db").path

        var config = Configuration()
        config.prepareDatabase { db in
            // Performance PRAGMAs
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -64000")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        try migrate()
        logger.info("[Database] Opened at \(dbPath)")
    }

    // MARK: - Migration

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull()
                t.column("timestampStart", .integer).notNull()
                t.column("timestampEnd", .integer).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("language", .text)
                t.column("audioPath", .text)
                t.column("model", .text).defaults(to: "whisperkit")
                t.column("confidence", .double)
                t.column("createdAt", .integer).notNull()
            }
            try db.create(index: "idx_transcriptions_timestamp", on: "transcriptions", columns: ["timestampStart"])

            try db.create(table: "summaries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("windowStart", .integer).notNull()
                t.column("windowEnd", .integer).notNull()
                t.column("rawText", .text).notNull()
                t.column("summaryText", .text)
                t.column("transcriptionCount", .integer).notNull()
                t.column("model", .text)
                t.column("createdAt", .integer).notNull()
            }
            try db.create(index: "idx_summaries_window", on: "summaries", columns: ["windowStart"])

            // FTS5 for full-text search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcriptions_fts USING fts5(
                    text,
                    content='transcriptions',
                    content_rowid='id',
                    tokenize='trigram'
                )
            """)

            // I7: FTS5 content-sync triggers
            try db.execute(sql: """
                CREATE TRIGGER transcriptions_ai AFTER INSERT ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(rowid, text) VALUES (new.id, new.text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER transcriptions_ad AFTER DELETE ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(transcriptions_fts, rowid, text) VALUES('delete', old.id, old.text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER transcriptions_au AFTER UPDATE ON transcriptions BEGIN
                    INSERT INTO transcriptions_fts(transcriptions_fts, rowid, text) VALUES('delete', old.id, old.text);
                    INSERT INTO transcriptions_fts(rowid, text) VALUES (new.id, new.text);
                END
            """)

            // I2: Unique index to prevent duplicate summaries
            try db.create(
                index: "idx_summaries_unique_window",
                on: "summaries",
                columns: ["windowStart", "windowEnd"],
                unique: true,
                ifNotExists: true
            )
        }

        try migrator.migrate(dbQueue)
        logger.info("[Database] Migrations complete")
    }

    // MARK: - Transcriptions CRUD

    func insertTranscription(_ transcription: Transcription) throws -> Transcription {
        try dbQueue.write { db in
            var record = transcription
            try record.insert(db)
            logger.info("[Database] Inserted transcription id=\(record.id ?? -1), \(record.text.prefix(50))...")
            // FTS5 sync handled by database trigger (transcriptions_ai)
            return record
        }
    }

    func transcriptionsInRange(start: Int64, end: Int64) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.timestampStart >= start)
                .filter(Transcription.Columns.timestampEnd <= end)
                .order(Transcription.Columns.timestampStart)
                .fetchAll(db)
        }
    }

    func transcriptionsForWindow(windowStart: Int64, windowEnd: Int64) throws -> [Transcription] {
        try transcriptionsInRange(start: windowStart, end: windowEnd)
    }

    func todayTranscriptionCount() throws -> Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        return try dbQueue.read { db in
            try Transcription
                .filter(Transcription.Columns.timestampStart >= startMs)
                .fetchCount(db)
        }
    }

    // MARK: - Summaries CRUD

    /// I6: Handle unique constraint gracefully — returns existing record on conflict.
    func insertSummary(_ summary: Summary) throws -> Summary {
        try dbQueue.write { db in
            var record = summary
            do {
                try record.insert(db)
                logger.info("[Database] Inserted summary window=\(record.windowStart), count=\(record.transcriptionCount)")
            } catch let dbError as DatabaseError where dbError.resultCode == .SQLITE_CONSTRAINT {
                logger.info("[Database] Summary already exists for window \(record.windowStart), skipped")
            }
            return record
        }
    }

    func todaySummaries() throws -> [Summary] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        return try dbQueue.read { db in
            try Summary
                .filter(Summary.Columns.windowStart >= startMs)
                .order(Summary.Columns.windowStart.desc)
                .fetchAll(db)
        }
    }

    func summariesInRange(start: Int64, end: Int64) throws -> [Summary] {
        try dbQueue.read { db in
            try Summary
                .filter(Summary.Columns.windowStart >= start)
                .filter(Summary.Columns.windowEnd <= end)
                .order(Summary.Columns.windowStart.desc)
                .fetchAll(db)
        }
    }

    // MARK: - FTS5 Search

    /// I8: Sanitize query for FTS5 trigram tokenizer — wrap in double quotes for literal matching.
    func searchTranscriptions(query: String, limit: Int = 50) throws -> [Transcription] {
        let sanitized = query
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return [] }

        return try dbQueue.read { db in
            let ftsQuery = "\"\(sanitized)\""
            let sql = """
                SELECT t.* FROM transcriptions t
                JOIN transcriptions_fts fts ON t.id = fts.rowid
                WHERE transcriptions_fts MATCH ?
                ORDER BY t.timestampStart DESC
                LIMIT ?
            """
            return try Transcription.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
        }
    }

    // MARK: - Stats

    func totalTranscriptionCount() throws -> Int {
        try dbQueue.read { db in
            try Transcription.fetchCount(db)
        }
    }

    func totalSummaryCount() throws -> Int {
        try dbQueue.read { db in
            try Summary.fetchCount(db)
        }
    }
}
