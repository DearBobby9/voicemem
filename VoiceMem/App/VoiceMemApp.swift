import SwiftUI
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "App")

@main
struct VoiceMemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("VoiceMem", id: "timeline") {
            AppWindowRootView(appDelegate: appDelegate)
        }
        .defaultSize(width: 780, height: 620)

        MenuBarExtra {
            AppMenuBarRootView(appDelegate: appDelegate)
        } label: {
            AppMenuBarLabelView(appDelegate: appDelegate)
        }
        .menuBarExtraStyle(.window)

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

        do {
            let p = try PipelineCoordinator()
            self.pipeline = p
            logger.info("[App] Pipeline initialized (not recording — user must start)")

            // Auto-load model if previously downloaded (fast, from cache)
            Task {
                await p.tryAutoLoadModel()
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
            } else if let error = appDelegate.launchError {
                ContentUnavailableView("启动失败", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                ProgressView("正在初始化…")
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
            } else {
                VStack(spacing: 8) {
                    Text("VoiceMem 未就绪").font(.caption)
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .font(.caption).buttonStyle(.plain)
                }
                .padding().frame(width: 200)
            }
        }
    }
}

struct AppMenuBarLabelView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        Label("VoiceMem", systemImage: iconName)
    }

    private var iconName: String {
        guard let p = appDelegate.pipeline else { return "waveform.slash" }
        if !p.isRunning { return "waveform.slash" }
        return p.isPaused ? "waveform.badge.minus" : "waveform"
    }
}
