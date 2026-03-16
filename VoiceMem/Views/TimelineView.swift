import SwiftUI

/// Dayflow-style vertical timeline — shows individual transcriptions and 15-minute summaries.
struct TimelineView: View {
    let pipeline: PipelineCoordinator

    @State private var transcriptions: [Transcription] = []
    @State private var isLoading = true
    @State private var selectedDate = Date()
    @State private var loadTask: Task<Void, Never>?
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBar
            Divider()

            if isLoading {
                loadingState
            } else if transcriptions.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .onAppear { loadData(); startRefreshTimer() }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: selectedDate) { _, _ in loadData() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("VoiceMem")
                .font(.title2.bold())

            Spacer()

            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            // Recording indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(pipeline.isRunning && !pipeline.isPaused ? .green : .gray)
                    .frame(width: 6, height: 6)
                Text(pipeline.isRunning ? (pipeline.isPaused ? "已暂停" : "录制中") : "未运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if pipeline.vad.isSpeechDetected {
                HStack(spacing: 3) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                    Text("检测到语音")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }

            Spacer()

            Text("\(transcriptions.count) 条记录")
                .font(.caption)
                .foregroundStyle(.secondary)

            if pipeline.transcription.isLoading {
                ProgressView()
                    .controlSize(.mini)
                Text("加载模型中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(transcriptions) { item in
                    TranscriptionRow(transcription: item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("正在加载…")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("今天还没有语音记录")
                .foregroundStyle(.secondary)
            if !pipeline.isRunning {
                Text("点击菜单栏图标开始录制")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func loadData() {
        loadTask?.cancel()

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: selectedDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)
        let database = pipeline.database

        isLoading = true
        loadTask = Task {
            let loaded = (try? await Task.detached(priority: .utility) {
                try database.transcriptionsInRange(start: startMs, end: endMs)
            }.value) ?? []
            guard !Task.isCancelled else {
                await MainActor.run { isLoading = false }
                return
            }
            await MainActor.run {
                transcriptions = loaded
                isLoading = false
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                loadData()
            }
        }
    }
}

// MARK: - Transcription Row

struct TranscriptionRow: View {
    let transcription: Transcription

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timestamp
            Text(Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(transcription.timestampStart) / 1000)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            // Timeline dot + line
            VStack(spacing: 0) {
                Circle()
                    .fill(.blue)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1.5)
            }
            .frame(width: 10)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(transcription.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if let lang = transcription.language {
                        Text(lang)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Text(formatDuration(transcription.durationMs))
                    if transcription.audioPath != nil {
                        Image(systemName: "speaker.wave.2")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal)
    }

    private func formatDuration(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m\(secs)s"
    }
}
