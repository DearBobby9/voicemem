import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Pipeline")

/// Orchestrates the full recording pipeline:
/// AudioCapture → VAD → Transcription → Database → SummaryAggregation.
///
/// This class lives in Core/ and does NOT depend on any UI.
@MainActor
@Observable
final class PipelineCoordinator {
    let audioCapture: AudioCaptureManager
    let vad: VADManager
    let transcription: TranscriptionManager
    let database: DatabaseManager
    let aggregator: SummaryAggregator

    private var sleepWakeMonitor: SleepWakeMonitor?
    private var vadBusy = false  // I2: back-pressure for audio→VAD path

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

        // Check microphone permission
        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            self.error = "需要麦克风权限才能录音。请在系统设置中允许。"
            logger.error("[Pipeline] Microphone permission denied")
            return
        }

        // I1: Apply settings from UserDefaults
        applySettings()

        try await transcription.loadModel()
        try audioCapture.start()
        aggregator.start()

        // I5: Run backfill async to avoid blocking main actor
        Task { @MainActor in
            aggregator.backfillMissingSummaries()
        }

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
        sleepWakeMonitor?.removeAllObservers()
        sleepWakeMonitor = nil
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

    // MARK: - Settings (I1)

    func applySettings() {
        let defaults = UserDefaults.standard
        let threshold = defaults.double(forKey: "vadThreshold")
        if threshold > 0 {
            vad.threshold = Float(threshold)
            logger.info("[Pipeline] Applied VAD threshold: \(threshold)")
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Audio → VAD (with back-pressure: drop if busy)
        audioCapture.onAudioBuffer = { [weak self] samples, timestamp in
            Task { @MainActor [weak self] in
                guard let self, !self.vadBusy else { return }
                self.vadBusy = true
                self.vad.process(samples: samples, timestamp: timestamp)
                self.vadBusy = false
            }
        }

        // VAD → Transcription + Audio Encoding → Database
        vad.onSpeechSegment = { [weak self] (segment: AudioSegment) in
            Task { @MainActor [weak self] in
                await self?.encodeTranscribeAndStore(segment)
            }
        }
    }

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
            let transcriptionRecord = Transcription(
                text: result.text,
                timestampStart: segment.timestampStart,
                timestampEnd: segment.timestampEnd,
                language: result.language,
                audioPath: audioPath,
                model: result.model,
                confidence: result.confidence
            )

            let record = try database.insertTranscription(transcriptionRecord)
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
