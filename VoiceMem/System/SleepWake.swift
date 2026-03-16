import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "SleepWake")

/// Handles macOS sleep/wake events — pauses recording on sleep, resumes on wake.
/// I3+I4: uses closure-based observers (no NSObject needed) with proper cleanup.
@MainActor
final class SleepWakeMonitor {
    private weak var pipeline: PipelineCoordinator?
    private var wasRunningBeforeSleep = false
    private var observers: [any NSObjectProtocol] = []

    init(pipeline: PipelineCoordinator) {
        self.pipeline = pipeline
        registerObservers()
    }

    func removeAllObservers() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSleep()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { _ in
            logger.info("[SleepWake] Screens off (lid closed)")
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { _ in
            logger.info("[SleepWake] Screens on (lid opened)")
        })
    }

    private func handleSleep() {
        guard let pipeline else { return }
        wasRunningBeforeSleep = pipeline.isRunning && !pipeline.isPaused
        if wasRunningBeforeSleep {
            pipeline.pause()
        }
        logger.info("[SleepWake] System sleeping, was running: \(self.wasRunningBeforeSleep)")
    }

    private func handleWake() {
        guard let pipeline, wasRunningBeforeSleep else { return }
        do {
            try pipeline.resume()
            logger.info("[SleepWake] System woke, resumed recording")
        } catch {
            logger.error("[SleepWake] Failed to resume: \(error.localizedDescription)")
        }
    }
}
