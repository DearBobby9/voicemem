import SwiftUI
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "App")

@main
struct VoiceMemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Main timeline window
        Window("VoiceMem", id: "timeline") {
            if let pipeline = appDelegate.pipeline {
                TimelineView(pipeline: pipeline)
            } else {
                ProgressView("Loading...")
            }
        }
        .defaultSize(width: 420, height: 700)

        // Menu bar icon
        MenuBarExtra {
            if let pipeline = appDelegate.pipeline {
                MenuBarView(pipeline: pipeline)
            }
        } label: {
            Label(
                "VoiceMem",
                systemImage: appDelegate.pipeline?.isRunning == true
                    ? (appDelegate.pipeline?.isPaused == true ? "waveform.badge.minus" : "waveform")
                    : "waveform.slash"
            )
        }
        .menuBarExtraStyle(.window)

        // Settings
        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pipeline: PipelineCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("[App] Launching VoiceMem")
        NSApp.setActivationPolicy(.accessory)

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
                }
            }
        } catch {
            logger.error("[App] Pipeline init failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pipeline?.stop()
        logger.info("[App] Terminated")
    }
}
