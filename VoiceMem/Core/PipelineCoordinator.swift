import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Pipeline")

/// Orchestrates the full recording pipeline.
/// User explicitly starts/stops recording. Model must be loaded first.
@MainActor
@Observable
final class PipelineCoordinator {

    // MARK: Sub-systems

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

    /// Whether the user can press "开始录音"
    var canStartRecording: Bool {
        transcription.isModelLoaded && !isRunning
    }

    /// Human-readable status for UI
    var statusText: String {
        if transcription.isLoading { return transcription.loadingProgress.isEmpty ? "正在加载模型…" : transcription.loadingProgress }
        if !transcription.isModelLoaded { return "需要配置转录模型" }
        if !isRunning { return "就绪，点击开始录音" }
        if isPaused { return "已暂停" }
        if vad.isSpeechDetected { return "检测到语音" }
        return "录制中"
    }

    // MARK: Private

    private var sleepWakeMonitor: SleepWakeMonitor?
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

    // MARK: - Model Management

    /// Try to auto-load model from cache (fast if already downloaded).
    func tryAutoLoadModel() async {
        do {
            try await transcription.loadModel()
        } catch {
            // Not an error — user just hasn't downloaded a model yet
            logger.info("[Pipeline] Model not available yet: \(error.localizedDescription)")
        }
    }

    /// Download/switch model explicitly (from Settings).
    func loadModel(_ modelId: String) async throws {
        try await transcription.loadModel(modelId: modelId)
        logger.info("[Pipeline] Model \(modelId) ready")
    }

    // MARK: - Recording Control (user-triggered)

    func startRecording() async throws {
        guard !isRunning else { return }
        guard transcription.isModelLoaded else {
            self.error = "请先在设置中选择并下载转录模型"
            return
        }
        error = nil

        let granted = await PermissionManager.requestMicrophoneAccess()
        guard granted else {
            self.error = "需要麦克风权限。请在系统设置 → 隐私与安全 → 麦克风 中允许 VoiceMem。"
            return
        }

        applySettings()
        try audioCapture.start()
        aggregator.start()
        sleepWakeMonitor = SleepWakeMonitor(pipeline: self)

        let retentionDays = UserDefaults.standard.integer(forKey: AppSettingsKey.audioRetentionDays)
        StorageCleanup.cleanOldAudioFiles(retentionDays: retentionDays > 0 ? retentionDays : 7)

        startAudioConsumerTask()

        isRunning = true
        isPaused = false
        logger.info("[Pipeline] Recording started")

        aggregator.startBackfill()
    }

    func stopRecording() {
        audioConsumerTask?.cancel()
        audioConsumerTask = nil
        audioCapture.stop()
        aggregator.stop()
        sleepWakeMonitor?.removeAllObservers()
        sleepWakeMonitor = nil
        isRunning = false
        isPaused = false
        logger.info("[Pipeline] Recording stopped")
    }

    func pause() {
        audioCapture.pause()
        isPaused = true
        logger.info("[Pipeline] Paused")
    }

    func resume() throws {
        try audioCapture.resume()
        isPaused = false
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
        let threshold = d.double(forKey: AppSettingsKey.vadThreshold)
        if threshold > 0 { vad.threshold = Float(threshold) }
        let minSpeech = d.integer(forKey: AppSettingsKey.vadMinSpeechMs)
        if minSpeech > 0 { vad.minSpeechMs = Int64(minSpeech) }
        let maxSegment = d.integer(forKey: AppSettingsKey.vadMaxSegmentMs)
        if maxSegment > 0 { vad.maxSegmentMs = Int64(maxSegment) }
        let silenceTrigger = d.integer(forKey: AppSettingsKey.vadSilenceTriggerMs)
        if silenceTrigger > 0 { vad.silenceTriggerMs = Int64(silenceTrigger) }
        logger.info("[Pipeline] Settings applied")
    }

    // MARK: - Audio Consumer

    private func startAudioConsumerTask() {
        let stream = audioCapture.audioStream
        let vad = self.vad
        var bufferCount = 0

        audioConsumerTask = Task {
            for await buffer in stream {
                if Task.isCancelled { break }
                bufferCount += 1
                if bufferCount % 200 == 1 {
                    let rms = sqrt(buffer.samples.reduce(0) { $0 + $1 * $1 } / max(1, Float(buffer.samples.count)))
                    logger.info("[Pipeline] Buffer #\(bufferCount): RMS=\(String(format: "%.4f", rms))")
                }
                await MainActor.run {
                    vad.process(samples: buffer.samples, timestamp: buffer.timestampMs)
                }
            }
        }
    }

    // MARK: - VAD → Transcription

    private func wireVADCallback() {
        vad.onSpeechSegment = { [weak self] segment in
            Task { @MainActor [weak self] in
                await self?.encodeTranscribeAndStore(segment)
            }
        }
    }

    private func encodeTranscribeAndStore(_ segment: AudioSegment) async {
        do {
            let audioFilename: String?
            do {
                audioFilename = try AudioEncoder.encode(segment: segment, sampleRate: audioCapture.sampleRate)
            } catch {
                logger.error("[Pipeline] Encoding failed: \(error.localizedDescription)")
                audioFilename = nil
            }

            let result = try await transcription.transcribe(segment: segment)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            let saved = try database.insertTranscription(result)
            lastTranscription = saved
            refreshTodayCount()
            logger.info("[Pipeline] Transcribed: \(result.text.prefix(60))...")
        } catch {
            logger.error("[Pipeline] Error: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    func refreshTodayCount() {
        todayCount = (try? database.todayTranscriptionCount()) ?? 0
    }

    // Legacy compatibility
    func start() async throws { try await startRecording() }
    func stop() { stopRecording() }
}
