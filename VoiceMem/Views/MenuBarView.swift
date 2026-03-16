import SwiftUI

/// Menu bar popover — compact: status + latest transcription + controls.
struct MenuBarView: View {
    let pipeline: PipelineCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: status + quit
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(pipeline.isRunning && !pipeline.isPaused ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(statusText).font(.system(size: 13, weight: .medium))
                }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .font(.caption).foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            // Latest transcription
            VStack(alignment: .leading, spacing: 4) {
                Text("最近转录").font(.system(size: 11)).foregroundStyle(.tertiary)
                if let last = pipeline.lastTranscription {
                    Text(last.text).font(.callout).lineLimit(3)
                    HStack(spacing: 6) {
                        Text(formatTime(last.timestampStart))
                        if let lang = last.language { Text("·"); Text(lang) }
                        Text("·")
                        Text(formatDuration(last.durationMs))
                    }
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Text("暂无").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            // Error
            if let error = pipeline.error {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }

            Divider()

            // Controls
            HStack(spacing: 8) {
                Button {
                    try? pipeline.togglePause()
                } label: {
                    Label(pipeline.isPaused ? "恢复" : "暂停",
                          systemImage: pipeline.isPaused ? "play.fill" : "pause.fill")
                }

                Spacer()

                Button { openWindow(id: "timeline") } label: {
                    Label("时间轴", systemImage: "clock")
                }

                Spacer()

                SettingsLink { Label("设置", systemImage: "gear") }
            }
            .font(.system(size: 12)).buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 300)
    }

    private var statusText: String {
        if !pipeline.isRunning { return "未运行" }
        if pipeline.isPaused { return "已暂停" }
        if pipeline.vad.isSpeechDetected { return "检测到语音" }
        return "录制中"
    }

    private func formatTime(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func formatDuration(_ ms: Int64) -> String {
        String(format: "%.1fs", Double(ms) / 1000)
    }
}
