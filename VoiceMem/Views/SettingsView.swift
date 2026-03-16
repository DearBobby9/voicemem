import SwiftUI

/// macOS System Preferences style settings: sidebar navigation + detail panel.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .recording

    var body: some View {
        HSplitView {
            // Sidebar
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .font(.system(size: 12))
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            // Detail
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    selectedTab.detailView
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420)
        }
        .frame(width: 620, height: 520)
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case recording, vad, transcription, summary, storage, system, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recording: "录音"
        case .vad: "语音检测"
        case .transcription: "转录"
        case .summary: "摘要"
        case .storage: "存储"
        case .system: "系统"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .recording: "mic.fill"
        case .vad: "waveform"
        case .transcription: "text.bubble"
        case .summary: "sparkles"
        case .storage: "externaldrive"
        case .system: "gearshape"
        case .about: "info.circle"
        }
    }

    @ViewBuilder var detailView: some View {
        switch self {
        case .recording: RecordingSettings()
        case .vad: VADSettings()
        case .transcription: TranscriptionSettings()
        case .summary: SummarySettings()
        case .storage: StorageSettings()
        case .system: SystemSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Recording

struct RecordingSettings: View {
    @AppStorage(AppSettingsKey.selectedMicrophone) private var mic = "default"
    @AppStorage(AppSettingsKey.autoStart) private var autoStart = true

    var body: some View {
        SettingsPageHeader(title: "录音", description: "控制麦克风输入和录音行为")

        SettingsGroup {
            SettingsRow("输入设备") { Text("MacBook Pro Microphone").foregroundStyle(.secondary) }
            SettingsRow("启动时自动录音") { Toggle("", isOn: $autoStart).labelsHidden() }
        }
    }
}

// MARK: - VAD

struct VADSettings: View {
    @AppStorage(AppSettingsKey.vadThreshold) private var threshold = 0.5
    @AppStorage(AppSettingsKey.vadMinSpeechMs) private var minSpeech = 500
    @AppStorage(AppSettingsKey.vadMaxSegmentMs) private var maxSegment = 28000
    @AppStorage(AppSettingsKey.vadSilenceTriggerMs) private var silenceTrigger = 1500

    var body: some View {
        SettingsPageHeader(title: "语音检测", description: "调节 VAD 参数来控制什么样的声音会被录入和切段")

        SettingsGroup(title: "灵敏度") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("检测阈值")
                    Spacer()
                    Text(String(format: "%.2f", threshold)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: $threshold, in: 0.1...0.9, step: 0.05)
                HStack { Text("灵敏").font(.caption2); Spacer(); Text("严格").font(.caption2) }
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }

        SettingsGroup(title: "切段规则") {
            SettingsSliderRow("最短语音段", value: $minSpeech, range: 200...2000, step: 100, unit: "ms",
                             hint: "短于此时长的声音丢弃（过滤咳嗽、敲击）")
            Divider()
            SettingsSliderRow("最长语音段", value: $maxSegment, range: 5000...60000, step: 1000, unit: "ms",
                             hint: "超过此时长自动切段送去转录", displayDivisor: 1000, displayUnit: "s")
            Divider()
            SettingsSliderRow("静音切段延迟", value: $silenceTrigger, range: 500...5000, step: 100, unit: "ms",
                             hint: "停止说话后等多久结束当前段", displayDivisor: 1000, displayUnit: "s")
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @AppStorage(AppSettingsKey.whisperModel) private var modelId = WhisperModel.defaultModel
    @AppStorage(AppSettingsKey.transcriptionLanguage) private var language = TranscriptionLanguage.auto.rawValue
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var downloadSuccess = false

    var body: some View {
        SettingsPageHeader(title: "转录", description: "WhisperKit 语音识别模型配置。更大的模型精度更高但占用更多资源。")

        SettingsGroup {
            SettingsRow("转录模型") {
                Picker("", selection: $modelId) {
                    ForEach(WhisperModel.allModels) { model in
                        Text("\(model.displayName)  \(model.size)").tag(model.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(isDownloading)
            }
            Divider()
            SettingsRow("语言偏好") {
                Picker("", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }

        // Download button
        SettingsGroup {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载 / 加载模型").font(.system(size: 13))
                    if isDownloading {
                        Text("正在下载中，请稍候…").font(.caption).foregroundStyle(.secondary)
                    } else if downloadSuccess {
                        Text("模型已就绪").font(.caption).foregroundStyle(.green)
                    } else if let err = downloadError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else {
                        Text("首次使用需下载模型文件").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(downloadSuccess ? "重新加载" : "下载模型") {
                        downloadModel()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }

        if let model = WhisperModel.allModels.first(where: { $0.id == modelId }) {
            SettingsGroup(title: "模型信息") {
                SettingsInfoRow("模型大小", value: model.size)
                Divider()
                SettingsInfoRow("语言支持", value: model.languages)
                Divider()
                SettingsInfoRow("运行硬件", value: "Apple Neural Engine")
            }
        }

        Text("选择模型后点击「下载模型」。下载完成后回到主窗口点击「开始录音」。")
            .font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
    }

    private func downloadModel() {
        isDownloading = true
        downloadError = nil
        downloadSuccess = false
        Task {
            do {
                let mgr = TranscriptionManager()
                try await mgr.loadModel(modelId: modelId)
                downloadSuccess = true
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

// MARK: - Summary

struct SummarySettings: View {
    @AppStorage(AppSettingsKey.summaryIntervalMinutes) private var interval = 15
    @AppStorage(AppSettingsKey.summaryEngine) private var engine = SummaryEngine.off.rawValue

    var body: some View {
        SettingsPageHeader(title: "摘要", description: "配置阶段性语音摘要的生成方式")

        SettingsGroup {
            SettingsRow("摘要间隔") {
                Picker("", selection: $interval) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                }
                .labelsHidden().frame(width: 120)
            }
            Divider()
            SettingsRow("AI 摘要引擎") {
                Picker("", selection: $engine) {
                    ForEach(SummaryEngine.allCases) { e in
                        Text(e.displayName).tag(e.rawValue)
                    }
                }
                .labelsHidden().frame(width: 160)
            }
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SummaryEngine.allCases) { e in
                    HStack(alignment: .top, spacing: 6) {
                        Text(e.displayName).font(.caption).fontWeight(.medium).frame(width: 110, alignment: .leading)
                        Text(e.description).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(4)
        }
        .padding(.top, 4)
    }
}

// MARK: - Storage

struct StorageSettings: View {
    @AppStorage(AppSettingsKey.audioRetentionDays) private var retention = 7
    @State private var showClearConfirm = false
    @State private var clearSuccess: Bool?

    var body: some View {
        SettingsPageHeader(title: "存储", description: "管理音频文件保留策略和数据导出")

        SettingsGroup {
            SettingsRow("音频保留") {
                Picker("", selection: $retention) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("永久").tag(-1)
                }
                .labelsHidden().frame(width: 100)
            }
        }

        Text("转录文本永久保留，仅按保留周期清理音频文件。")
            .font(.caption).foregroundStyle(.tertiary).padding(.vertical, 4)

        // Stats
        HStack(spacing: 12) {
            StatCard(value: formatBytes(AudioEncoder.totalStorageBytes()), label: "音频")
            StatCard(value: "—", label: "数据库")
        }
        .padding(.vertical, 4)

        SettingsGroup {
            SettingsRow("导出数据") {
                HStack(spacing: 6) {
                    Button("Markdown") { /* TODO */ }.controlSize(.small)
                    Button("JSON") { /* TODO */ }.controlSize(.small)
                }
            }
        }

        // Danger zone
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清空所有数据").font(.system(size: 13))
                    Text("删除转录、摘要和音频文件，不可恢复").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("清空数据…") { showClearConfirm = true }
                    .foregroundStyle(.red)
                    .controlSize(.small)
            }
            .padding(4)
        }
        .padding(.top, 8)
        .alert("确定要清空所有数据吗？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                do {
                    let db = try DatabaseManager()
                    try db.clearAllData()
                    clearSuccess = true
                } catch {
                    clearSuccess = false
                }
            }
        } message: {
            Text("这将删除所有转录文本、摘要和音频文件。此操作不可恢复。")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb < 1 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", mb)
    }
}

struct StatCard: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold))
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - System

struct SystemSettings: View {
    @AppStorage(AppSettingsKey.launchAtLogin) private var launchAtLogin = true
    @AppStorage(AppSettingsKey.notifyOnTranscription) private var notify = false

    var body: some View {
        SettingsPageHeader(title: "系统", description: "启动行为、通知和快捷键")

        SettingsGroup {
            SettingsRow("开机自启") {
                Toggle("", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { _, v in LoginItemManager.setEnabled(v) }
            }
            Divider()
            SettingsRow("新转录通知") {
                Toggle("", isOn: $notify).labelsHidden()
            }
            Divider()
            SettingsRow("全局快捷键") {
                Text("⌘⇧R").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }

        Text("通知默认关闭，避免持续打扰。快捷键用于暂停/恢复录制。")
            .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
    }
}

// MARK: - About

struct AboutSettings: View {
    var body: some View {
        SettingsPageHeader(title: "关于", description: nil)

        SettingsGroup {
            SettingsInfoRow("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
            Divider()
            SettingsInfoRow("数据位置", value: "~/Library/.../VoiceMem/")
            Divider()
            HStack {
                Text("GitHub")
                Spacer()
                Link("DearBobby9/voicemem", destination: URL(string: "https://github.com/DearBobby9/voicemem")!)
                    .font(.system(size: 12))
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Reusable Components

struct SettingsPageHeader: View {
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            if let desc = description {
                Text(desc).font(.caption).foregroundStyle(.tertiary).lineSpacing(2)
            }
        }
        .padding(.bottom, 16)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 12)
    }
}

struct SettingsRow<Trailing: View>: View {
    let label: String
    @ViewBuilder let trailing: Trailing

    init(_ label: String, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SettingsSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    var hint: String? = nil
    var displayDivisor: Double = 1
    var displayUnit: String? = nil

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String,
         hint: String? = nil, displayDivisor: Double = 1, displayUnit: String? = nil) {
        self.label = label; self._value = value; self.range = range; self.step = step
        self.unit = unit; self.hint = hint; self.displayDivisor = displayDivisor
        self.displayUnit = displayUnit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13))
                    if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                Text(displayValue).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
        }
        .padding(.vertical, 4)
    }

    private var displayValue: String {
        if displayDivisor > 1 {
            return String(format: "%.1f%@", Double(value) / displayDivisor, displayUnit ?? unit)
        }
        return "\(value)\(displayUnit ?? unit)"
    }
}
