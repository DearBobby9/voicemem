import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "SummaryAggregator")

/// Aggregates transcriptions into 15-minute summary blocks (Dayflow-style).
/// MVP: pure text concatenation. Plugin: AI summary fills `summaryText`.
@MainActor
@Observable
final class SummaryAggregator {
    private let database: DatabaseManager
    private var timer: Timer?
    private let windowMinutes: Int = 15

    private(set) var lastAggregatedWindow: Int64 = 0

    init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Timer Lifecycle

    func start() {
        let now = Date()
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let nextBoundary = (minute / windowMinutes + 1) * windowMinutes
        let minutesUntilNext = nextBoundary - minute

        let fireDate = calendar.date(byAdding: .minute, value: minutesUntilNext, to: now) ?? now

        timer = Timer(fire: fireDate, interval: TimeInterval(windowMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.aggregateLatestWindow()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        logger.info("[SummaryAggregator] Started, next fire in \(minutesUntilNext) minutes")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("[SummaryAggregator] Stopped")
    }

    // MARK: - Aggregation

    /// Trigger aggregation for the most recently completed window.
    /// I1 fix: use simple arithmetic instead of Calendar.date(bySetting:)
    func aggregateLatestWindow() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let windowMs = Int64(windowMinutes * 60 * 1000)
        let windowEnd = (nowMs / windowMs) * windowMs  // floor to current boundary
        let windowStart = windowEnd - windowMs

        aggregate(windowStart: windowStart, windowEnd: windowEnd)
    }

    /// Aggregate all transcriptions in a specific 15-minute window.
    func aggregate(windowStart: Int64, windowEnd: Int64) {
        do {
            // I2 fix: check for existing summary before inserting
            let existing = try database.summariesInRange(start: windowStart, end: windowEnd)
            guard existing.isEmpty else {
                logger.info("[SummaryAggregator] Summary already exists for window \(windowStart)")
                return
            }

            let transcriptions = try database.transcriptionsForWindow(
                windowStart: windowStart,
                windowEnd: windowEnd
            )

            guard !transcriptions.isEmpty else { return }

            let rawText = transcriptions
                .map { $0.text }
                .joined(separator: " ")

            let summary = Summary(
                windowStart: windowStart,
                windowEnd: windowEnd,
                rawText: rawText,
                transcriptionCount: transcriptions.count
            )

            _ = try database.insertSummary(summary)
            lastAggregatedWindow = windowStart

            logger.info("[SummaryAggregator] Aggregated \(transcriptions.count) transcriptions for window \(windowStart)")
        } catch {
            logger.error("[SummaryAggregator] Aggregation failed: \(error.localizedDescription)")
        }
    }

    /// Backfill summaries for any windows that were missed (e.g., after app restart).
    func backfillMissingSummaries() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let windowMs = Int64(windowMinutes * 60 * 1000)

        var windowStart = startMs
        while windowStart + windowMs <= nowMs {
            let windowEnd = windowStart + windowMs
            aggregate(windowStart: windowStart, windowEnd: windowEnd)
            windowStart = windowEnd
        }
    }
}
