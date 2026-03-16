import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "SleepWake")

/// Handles macOS sleep/wake events — pauses recording on sleep, resumes on wake.
@MainActor
final class SleepWakeMonitor {
    private weak var pipeline: PipelineCoordinator?
    private var wasRunningBeforeSleep = false

    init(pipeline: PipelineCoordinator) {
        self.pipeline = pipeline
        observeNotifications()
    }

    private func observeNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleScreensOff),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )

        workspace.addObserver(
            self,
            selector: #selector(handleScreensOn),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func handleSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let pipeline = self.pipeline else { return }
            self.wasRunningBeforeSleep = pipeline.isRunning && !pipeline.isPaused
            if self.wasRunningBeforeSleep {
                pipeline.pause()
            }
            logger.info("[SleepWake] System sleeping, was running: \(self.wasRunningBeforeSleep)")
        }
    }

    @objc private func handleWake(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let pipeline = self.pipeline, self.wasRunningBeforeSleep else { return }
            do {
                try pipeline.resume()
                logger.info("[SleepWake] System woke, resumed recording")
            } catch {
                logger.error("[SleepWake] Failed to resume after wake: \(error.localizedDescription)")
            }
        }
    }

    @objc private func handleScreensOff(_ notification: Notification) {
        logger.info("[SleepWake] Screens off (lid closed)")
    }

    @objc private func handleScreensOn(_ notification: Notification) {
        logger.info("[SleepWake] Screens on (lid opened)")
    }
}
