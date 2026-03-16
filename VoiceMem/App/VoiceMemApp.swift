import SwiftUI
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "App")

@main
struct VoiceMemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Main timeline window
        Window("VoiceMem", id: "timeline") {
            AppWindowRootView(appDelegate: appDelegate)
        }
        .defaultSize(width: 420, height: 700)

        // Menu bar icon
        MenuBarExtra {
            AppMenuBarRootView(appDelegate: appDelegate)
        } label: {
            AppMenuBarLabelView(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var pipeline: PipelineCoordinator?
    @Published private(set) var launchError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[App] Launching VoiceMem")
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.registerVoiceMemDefaults()
        launchError = nil

        do {
            let p = try PipelineCoordinator()
            self.pipeline = p
            logger.info("[App] Pipeline initialized")

            Task {
                do {
                    try await p.start()
                    logger.info("[App] Pipeline started")
                } catch {
                    logger.error("[App] Pipeline start failed: \(error.localizedDescription)")
                    self.pipeline = nil
                    self.launchError = error.localizedDescription
                }
            }
        } catch {
            logger.error("[App] Pipeline init failed: \(error.localizedDescription)")
            self.launchError = error.localizedDescription
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
        logger.info("[App] Terminated")
    }
}

// MARK: - Root Views

struct AppWindowRootView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let pipeline = appDelegate.pipeline {
                TimelineView(pipeline: pipeline)
            } else if let launchError = appDelegate.launchError {
                ContentUnavailableView(
                    "启动失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(launchError)
                )
            } else {
                ProgressView("Loading...")
            }
        }
    }
}

struct AppMenuBarRootView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Group {
            if let pipeline = appDelegate.pipeline {
                MenuBarView(pipeline: pipeline)
            } else if let launchError = appDelegate.launchError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("VoiceMem 启动失败", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("退出 VoiceMem") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .frame(width: 280)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在启动 VoiceMem…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(width: 220)
            }
        }
    }
}

struct AppMenuBarLabelView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Label("VoiceMem", systemImage: systemImage)
    }

    private var systemImage: String {
        guard let pipeline = appDelegate.pipeline else {
            return appDelegate.launchError == nil ? "waveform.circle" : "waveform.slash"
        }
        if !pipeline.isRunning {
            return "waveform.slash"
        }
        return pipeline.isPaused ? "waveform.badge.minus" : "waveform"
    }
}
