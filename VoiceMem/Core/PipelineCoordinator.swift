import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Pipeline")

/// Orchestrates the full recording pipeline:
/// AudioCapture → VAD → Transcription → Database → SummaryAggregation.
///
/// This class lives in Core/ and does NOT depend on any UI.
/// @MainActor because it holds @Observable state consumed by SwiftUI.
@MainActor
@Observable
final class PipelineCoordinator {
    let audioCapture: AudioCaptureManager
    let vad: VADManager
    let transcription: TranscriptionManager
    let database: DatabaseManager
    let aggregator: SummaryAggregator

    private var sleepWakeMonitor: SleepWakeMonitor?  // C2: must keep strong ref

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var todayCount = 0
    private(set) var lastTranscription: Transcription?
    private(set) var error: String?

    init() throws {
        let db = try DatabaseManager()
        self.database = db
        self.audioCapture = AudioCaptureManager()
        self.vad = VADManager()
        self.transcription = TranscriptionManager()
        self.aggregator = SummaryAggregator(database: db)

        wireCallbacks()
        refreshTodayCount()
    }

    // MARK: - Pipeline Control

    func start() async throws {
        guard !isRunning else { return }
        error = nil

        // C3: Request microphone permission before starting
        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            self.error = "需要麦克风权限才能录音。请在系统设置中允许。"
            logger.error("[Pipeline] Microphone permission denied")
            return
        }

        try await transcription.loadModel()
        try audioCapture.start()
        aggregator.start()
        aggregator.backfillMissingSummaries()

        // C2: Instantiate sleep/wake monitor
        sleepWakeMonitor = SleepWakeMonitor(pipeline: self)

        // Schedule storage cleanup
        let retentionDays = UserDefaults.standard.integer(forKey: "audioRetentionDays")
        StorageCleanup.cleanOldAudioFiles(retentionDays: retentionDays > 0 ? retentionDays : 7)

        isRunning = true
        isPaused = false
        logger.info("[Pipeline] Started")
    }

    func stop() {
        audioCapture.stop()
        aggregator.stop()
        isRunning = false
        isPaused = false
        logger.info("[Pipeline] Stopped")
    }

    func pause() {
        audioCapture.pause()
        isPaused = true
        logger.info("[Pipeline] Paused")
    }

    func resume() throws {
        try audioCapture.resume()
        isPaused = false
        logger.info("[Pipeline] Resumed")
    }

    func togglePause() throws {
        if isPaused {
            try resume()
        } else {
            pause()
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // C1: Audio callback runs on audio thread → dispatch to main actor for VAD
        audioCapture.onAudioBuffer = { [weak self] samples, timestamp in
            Task { @MainActor [weak self] in
                self?.vad.process(samples: samples, timestamp: timestamp)
            }
        }

        // VAD → Transcription + Audio Encoding → Database
        vad.onSpeechSegment = { [weak self] (segment: AudioSegment) in
            Task { @MainActor [weak self] in
                await self?.encodeTranscribeAndStore(segment)
            }
        }
    }

    // C4: Encode audio + transcribe + store
    private func encodeTranscribeAndStore(_ segment: AudioSegment) async {
        do {
            // Save audio file to disk
            let audioPath: String?
            do {
                audioPath = try AudioEncoder.encode(segment: segment)
            } catch {
                logger.error("[Pipeline] Audio encoding failed: \(error.localizedDescription)")
                audioPath = nil
            }

            // Transcribe
            let result = try await transcription.transcribe(segment: segment)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.info("[Pipeline] Skipped empty transcription")
                return
            }

            // Store with audio path
            let transcription = Transcription(
                text: result.text,
                timestampStart: segment.timestampStart,
                timestampEnd: segment.timestampEnd,
                language: result.language,
                audioPath: audioPath,
                model: result.model,
                confidence: result.confidence
            )

            let record = try database.insertTranscription(transcription)
            lastTranscription = record
            refreshTodayCount()

            logger.info("[Pipeline] Transcribed: \(result.text.prefix(80))...")
        } catch {
            logger.error("[Pipeline] Pipeline failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    private func refreshTodayCount() {
        todayCount = (try? database.todayTranscriptionCount()) ?? 0
    }
}
