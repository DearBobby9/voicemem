import SwiftUI

/// Main window: left timeline panel + right summary sidebar.
struct TimelineView: View {
    let pipeline: PipelineCoordinator

    @State private var transcriptions: [Transcription] = []
    @State private var summaries: [Summary] = []
    @State private var selectedDate = Date()
    @State private var isLoading = true
    @State private var loadTask: Task<Void, Never>?
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            statusBar
            Divider()
            HStack(spacing: 0) {
                timelinePanel
                Divider()
                summaryPanel
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { loadData(); startRefreshTimer() }
        .onDisappear { refreshTimer?.invalidate(); loadTask?.cancel() }
        .onChange(of: selectedDate) { _, _ in loadData() }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack {
            Text("VoiceMem").font(.title2.bold())
            Spacer()
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            // Status dot + text
            Circle()
                .fill(pipeline.isRunning && !pipeline.isPaused ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(pipeline.statusText)
                .font(.caption).foregroundStyle(.secondary)

            if pipeline.vad.isSpeechDetected && pipeline.isRunning {
                HStack(spacing: 2) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                    Text("语音")
                }.font(.caption).foregroundStyle(.green)
            }

            Spacer()

            if pipeline.transcription.isLoading {
                ProgressView().controlSize(.mini)
            }

            Text("\(transcriptions.count) 条")
                .font(.caption).foregroundStyle(.tertiary)

            // Start / Stop button
            if pipeline.isRunning {
                Button {
                    pipeline.stopRecording()
                } label: {
                    Label("停止", systemImage: "stop.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.plain).foregroundStyle(.red)
            } else if pipeline.canStartRecording {
                Button {
                    Task { try? await pipeline.startRecording() }
                } label: {
                    Label("开始录音", systemImage: "record.circle")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else if !pipeline.transcription.isModelLoaded && !pipeline.transcription.isLoading {
                SettingsLink {
                    Label("配置模型", systemImage: "arrow.down.circle")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Timeline Panel (Left, ~70%)

    private var timelinePanel: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("正在加载…")
                Spacer()
            } else if transcriptions.isEmpty {
                Spacer()
                if !pipeline.transcription.isModelLoaded && !pipeline.transcription.isLoading {
                    // No model — guide to settings
                    Image(systemName: "arrow.down.circle").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text("需要先下载转录模型").font(.headline).padding(.top, 8)
                    Text("前往 设置 → 转录 选择并下载模型").font(.caption).foregroundStyle(.tertiary)
                    SettingsLink {
                        Text("打开设置").font(.callout)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular).padding(.top, 8)
                } else if !pipeline.isRunning {
                    // Model ready but not recording
                    Image(systemName: "mic.slash").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text("点击上方「开始录音」").foregroundStyle(.secondary).padding(.top, 8)
                } else {
                    // Recording but no transcriptions yet
                    Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text("正在录音，等待语音…").foregroundStyle(.secondary).padding(.top, 8)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transcriptions) { tx in
                            TranscriptionRow(transcription: tx, playback: pipeline.playback)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            // Player bar
            if pipeline.playback.currentFile != nil {
                Divider()
                PlayerBar(playback: pipeline.playback)
            }
        }
        .frame(minWidth: 420)
    }

    // MARK: - Summary Panel (Right, ~30%)

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").font(.caption)
                Text("阶段摘要").font(.caption).fontWeight(.semibold)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if summaries.isEmpty && !isLoading {
                VStack {
                    Spacer()
                    Text("暂无摘要").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(summaries) { summary in
                            SummaryCard(summary: summary)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 240)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Data

    private func loadData() {
        loadTask?.cancel()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: selectedDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)
        let db = pipeline.database

        isLoading = true
        loadTask = Task {
            let (txs, sums) = await Task.detached(priority: .utility) {
                let txs = (try? db.transcriptionsInRange(start: startMs, end: endMs)) ?? []
                let sums = (try? db.summariesInRange(start: startMs, end: endMs)) ?? []
                return (txs, sums)
            }.value
            guard !Task.isCancelled else {
                await MainActor.run { isLoading = false }
                return
            }
            await MainActor.run {
                transcriptions = txs
                summaries = sums
                isLoading = false
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            Task { @MainActor in loadData() }
        }
    }
}

// MARK: - Transcription Row

struct TranscriptionRow: View {
    let transcription: Transcription
    let playback: AudioPlaybackManager

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var isThisPlaying: Bool {
        playback.isPlaying && playback.currentFile == transcription.audioPath
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Play button
            if let audioPath = transcription.audioPath {
                Button { playback.togglePlayPause(filename: audioPath) } label: {
                    Image(systemName: isThisPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isThisPlaying ? .green : .accentColor)
                }
                .buttonStyle(.plain)
                .frame(width: 32)
                .padding(.top, 2)
            } else {
                Color.clear.frame(width: 32)
            }

            // Time
            Text(Self.timeFmt.string(from: Date(timeIntervalSince1970: Double(transcription.timestampStart) / 1000)))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .trailing)
                .padding(.top, 3)

            // Dot + line
            VStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(.top, 6)
                Rectangle().fill(.quaternary).frame(width: 1.5)
            }
            .frame(width: 14)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(transcription.text)
                    .font(.callout).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let lang = transcription.language {
                        Text(lang)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(lang == "zh" ? Color.accentColor.opacity(0.12) : Color.purple.opacity(0.12))
                            .foregroundStyle(lang == "zh" ? Color.accentColor : Color.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(formatDuration(transcription.durationMs))
                        .font(.system(size: 10)).foregroundStyle(.quaternary)
                    if transcription.audioPath != nil {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 9)).foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private func formatDuration(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        return s < 60 ? String(format: "%.1fs", s) : "\(Int(s)/60)m\(Int(s)%60)s"
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let summary: Summary

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(fmtTime(summary.windowStart)) – \(fmtTime(summary.windowEnd))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(summary.transcriptionCount)")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }

            Text(summary.displayText)
                .font(.system(size: 11.5)).lineSpacing(2)
                .foregroundStyle(.secondary)
                .lineLimit(6)

            if summary.summaryText != nil {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                    Text("AI 摘要")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func fmtTime(_ ms: Int64) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - Player Bar

struct PlayerBar: View {
    let playback: AudioPlaybackManager

    var body: some View {
        HStack(spacing: 10) {
            Button { playback.isPlaying ? playback.pause() : playback.play(filename: playback.currentFile ?? "") } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(playback.currentFile ?? "").font(.caption).lineLimit(1)
                Text(formatTime(playback.currentTime) + " / " + formatTime(playback.duration))
                    .font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 160, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 3)
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * playback.progress, height: 3)
                }
                .frame(height: 3)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let fraction = location.x / geo.size.width
                    playback.seek(to: max(0, min(1, fraction)))
                }
            }
            .frame(height: 20)

            Button { playback.stop() } label: {
                Image(systemName: "xmark.circle").font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
