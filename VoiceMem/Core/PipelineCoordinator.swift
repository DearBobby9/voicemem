import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Pipeline")

/// Orchestrates the full recording pipeline:
/// AudioCapture → VAD → Transcription → Database → SummaryAggregation.
///
/// Audio data flows through an `AsyncStream<AudioBuffer>` produced by
/// `AudioCaptureManager`. The stream is consumed on a background task so the
/// audio render thread is never blocked and no actor-isolation assertions are
/// triggered.
@MainActor
@Observable
final class PipelineCoordinator {

    // MARK: Sub-systems (all @MainActor)

    let audioCapture: AudioCaptureManager
    let vad: VADManager
    let transcription: TranscriptionManager
    let database: DatabaseManager
    let aggregator: SummaryAggregator
    let playback: AudioPlaybackManager

    // MARK: Observable state

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var todayCount = 0
    private(set) var lastTranscription: Transcription?
    private(set) var error: String?

    // MARK: Private

    private var sleepWakeMonitor: SleepWakeMonitor?
    /// The Task that drains `audioCapture.audioStream` and feeds VAD.
    private var audioConsumerTask: Task<Void, Never>?

    // MARK: Init

    init() throws {
        let db = try DatabaseManager()
        self.database = db
        self.audioCapture = AudioCaptureManager()
        self.vad = VADManager()
        self.transcription = TranscriptionManager()
        self.aggregator = SummaryAggregator(database: db)
        self.playback = AudioPlaybackManager()

        refreshTodayCount()
        wireVADCallback()
    }

    // MARK: - Pipeline Control

    func start() async throws {
        guard !isRunning else { return }
        error = nil

        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            self.error = "需要麦克风权限才能录音。请在系统设置中允许。"
            logger.error("[Pipeline] Microphone permission denied")
            return
        }

        applySettings()

        try await transcription.loadModel()
        try audioCapture.start()
        aggregator.start()

        sleepWakeMonitor = SleepWakeMonitor(pipeline: self)

        let retentionDays = UserDefaults.standard.integer(forKey: "audioRetentionDays")
        StorageCleanup.cleanOldAudioFiles(retentionDays: retentionDays > 0 ? retentionDays : 7)

        // Start the background task that drains the audio stream.
        // This task runs on the cooperative thread pool — NOT on MainActor —
        // so it never blocks the UI and never touches actor-isolated state directly.
        startAudioConsumerTask()

        isRunning = true
        isPaused = false
        logger.info("[Pipeline] Started")

        aggregator.startBackfill()
    }

    func stop() {
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
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

        // Re-arm the consumer if it was cancelled.
        if audioConsumerTask == nil || audioConsumerTask?.isCancelled == true {
            startAudioConsumerTask()
        }
        logger.info("[Pipeline] Resumed")
    }

    func togglePause() throws {
        if isPaused { try resume() } else { pause() }
    }

    // MARK: - Settings

    func applySettings() {
        let d = UserDefaults.standard

        // VAD settings
        let threshold = d.double(forKey: AppSettingsKey.vadThreshold)
        if threshold > 0 { vad.threshold = Float(threshold) }

        let minSpeech = d.integer(forKey: AppSettingsKey.vadMinSpeechMs)
        if minSpeech > 0 { vad.minSpeechMs = Int64(minSpeech) }

        let maxSegment = d.integer(forKey: AppSettingsKey.vadMaxSegmentMs)
        if maxSegment > 0 { vad.maxSegmentMs = Int64(maxSegment) }

        let silenceTrigger = d.integer(forKey: AppSettingsKey.vadSilenceTriggerMs)
        if silenceTrigger > 0 { vad.silenceTriggerMs = Int64(silenceTrigger) }

        logger.info("[Pipeline] Applied settings: VAD threshold=\(threshold), minSpeech=\(minSpeech)ms, maxSegment=\(maxSegment)ms, silence=\(silenceTrigger)ms")
    }

    // MARK: - Audio consumer (background task)

    /// Spawns an unstructured `Task` that iterates `audioCapture.audioStream`.
    ///
    /// Why unstructured: the task outlives the `start()` call and must be
    /// explicitly cancelled by `stop()`. Structured child tasks would be scoped
    /// to the enclosing async function's lifetime.
    ///
    /// Concurrency model:
    ///   - The task body has NO `@MainActor` annotation, so Swift schedules it
    ///     on the cooperative thread pool.
    ///   - We capture the `stream` value before entering the task to avoid
    ///     crossing an actor boundary inside the task body (the `audioCapture`
    ///     property is @MainActor; capturing it inside a non-isolated task would
    ///     require an `await` hop which adds latency).
    ///   - VAD processing is pure CPU work on value types — fully safe off-actor.
    ///   - After VAD emits a segment the task hops back to MainActor only for
    ///     transcription + DB (where latency is irrelevant).
    private func startAudioConsumerTask() {
        // Capture the stream reference here (on MainActor) before leaving isolation.
        let stream = audioCapture.audioStream
        // Capture VAD by reference — VADManager is @MainActor, so calls to it
        // must hop back. We do that with `await MainActor.run`.
        let vad = self.vad

        var bufferCount = 0

        audioConsumerTask = Task {
            // This closure body is NOT isolated to MainActor.
            // It runs on the cooperative thread pool.
            for await buffer in stream {
                // Cooperative cancellation: exit cleanly on stop().
                if Task.isCancelled { break }

                bufferCount += 1
                if bufferCount % 100 == 1 {
                    let rms = sqrt(
                        buffer.samples.reduce(0) { $0 + $1 * $1 }
                        / max(1, Float(buffer.samples.count))
                    )
                    logger.info("[Pipeline] Buffer #\(bufferCount): \(buffer.samples.count) samples, RMS=\(String(format: "%.6f", rms))")
                }

                // VADManager.process() mutates @MainActor state, so we must hop.
                // `await MainActor.run` is a suspension point — it does NOT block
                // the cooperative thread. The audio stream keeps buffering (.bufferingNewest(16))
                // while we await, so render-thread back-pressure is zero.
                await MainActor.run {
                    vad.process(samples: buffer.samples, timestamp: buffer.timestampMs)
                }
            }
            logger.info("[Pipeline] Audio consumer task ended (cancelled=\(Task.isCancelled))")
        }
    }

    // MARK: - VAD → Transcription wiring

    /// Wire the VAD callback once at init time.
    /// `onSpeechSegment` is called on @MainActor (because VADManager is @MainActor
    /// and we call `vad.process` inside `await MainActor.run`).
    private func wireVADCallback() {
        vad.onSpeechSegment = { [weak self] segment in
            // Called on MainActor (same executor as VADManager).
            Task { @MainActor [weak self] in
                await self?.encodeTranscribeAndStore(segment)
            }
        }
    }

    // MARK: - Transcription + Storage

    private func encodeTranscribeAndStore(_ segment: AudioSegment) async {
        do {
            // Encode audio to WAV at hardware sample rate
            let audioFilename: String?
            do {
                audioFilename = try AudioEncoder.encode(segment: segment, sampleRate: audioCapture.sampleRate)
            } catch {
                logger.error("[Pipeline] Audio encoding failed: \(error.localizedDescription)")
                audioFilename = nil
            }

            // Transcribe (WhisperKit reads from the WAV file)
            let result = try await transcription.transcribe(segment: segment)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                logger.info("[Pipeline] Skipped empty transcription")
                return
            }

            let record = result  // TranscriptionManager now returns a full Transcription

            let saved = try database.insertTranscription(record)
            lastTranscription = saved
            refreshTodayCount()

            logger.info("[Pipeline] Transcribed: \(result.text.prefix(80))...")
        } catch {
            logger.error("[Pipeline] Pipeline error: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func refreshTodayCount() {
        todayCount = (try? database.todayTranscriptionCount()) ?? 0
    }
}
