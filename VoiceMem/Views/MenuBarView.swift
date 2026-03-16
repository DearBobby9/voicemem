import SwiftUI

/// Menu bar popover — status, controls, recent transcriptions.
struct MenuBarView: View {
    let pipeline: PipelineCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.headline)
                Spacer()
                Text("今日 \(pipeline.todayCount) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Recent transcription
            if let last = pipeline.lastTranscription {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(last.text)
                        .font(.callout)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("暂无转录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Error display
            if let error = pipeline.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Controls
            HStack {
                Button {
                    try? pipeline.togglePause()
                } label: {
                    Label(
                        pipeline.isPaused ? "恢复" : "暂停",
                        systemImage: pipeline.isPaused ? "play.fill" : "pause.fill"
                    )
                }

                Spacer()

                Button {
                    openWindow(id: "timeline")
                } label: {
                    Label("时间轴", systemImage: "clock")
                }

                Spacer()

                SettingsLink {
                    Label("设置", systemImage: "gear")
                }
            }
            .buttonStyle(.plain)

            Divider()

            Button("退出 VoiceMem") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if !pipeline.isRunning { return .gray }
        if pipeline.isPaused { return .yellow }
        if pipeline.audioCapture.isCapturing && pipeline.vad.isSpeechDetected { return .green }
        return .blue
    }

    private var statusText: String {
        if !pipeline.isRunning { return "未运行" }
        if pipeline.isPaused { return "已暂停" }
        if pipeline.vad.isSpeechDetected { return "检测到语音" }
        return "监听中"
    }
}
