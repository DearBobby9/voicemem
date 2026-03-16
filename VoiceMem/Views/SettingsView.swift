import SwiftUI

/// App settings — microphone, model, audio retention, launch at login.
struct SettingsView: View {
    @AppStorage("selectedMicrophone") private var selectedMicrophone = "default"
    @AppStorage("audioRetentionDays") private var audioRetentionDays = 7
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("autoStart") private var autoStart = true
    @AppStorage("vadThreshold") private var vadThreshold = 0.5

    var body: some View {
        Form {
            // Microphone
            Section("麦克风") {
                Picker("输入设备", selection: $selectedMicrophone) {
                    Text("系统默认").tag("default")
                    // TODO: enumerate available audio devices
                }
            }

            // Recording
            Section("录音") {
                Toggle("启动时自动录音", isOn: $autoStart)
                HStack {
                    Text("VAD 灵敏度")
                    Slider(value: $vadThreshold, in: 0.1...0.9, step: 0.05)
                    Text(String(format: "%.2f", vadThreshold))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            // Storage
            Section("存储") {
                Picker("音频保留", selection: $audioRetentionDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("永久").tag(-1)
                }
                Text("转录文本永久保留，仅清理音频文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // System
            Section("系统") {
                Toggle("开机自启", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItemManager.setEnabled(newValue)
                    }
            }

            // About
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                LabeledContent("数据位置", value: "~/Library/Application Support/VoiceMem/")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 400)
    }
}
