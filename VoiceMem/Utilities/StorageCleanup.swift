import Foundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "StorageCleanup")

/// Cleans up old audio files based on retention policy.
enum StorageCleanup {
    private static let audioDir: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceMem/audio", isDirectory: true)
    }()

    /// Remove audio files older than `retentionDays`. Pass -1 for permanent retention.
    static func cleanOldAudioFiles(retentionDays: Int) {
        guard retentionDays > 0 else {
            logger.info("[StorageCleanup] Permanent retention, skipping cleanup")
            return
        }

        let fm = FileManager.default
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
        let cutoffMs = Int64(cutoff.timeIntervalSince1970 * 1000)

        guard let files = try? fm.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil) else {
            return
        }

        var removedCount = 0
        for file in files {
            // Filename format: {timestampMs}.caf
            let name = file.deletingPathExtension().lastPathComponent
            guard let timestamp = Int64(name), timestamp < cutoffMs else { continue }

            do {
                try fm.removeItem(at: file)
                removedCount += 1
            } catch {
                logger.error("[StorageCleanup] Failed to remove \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if removedCount > 0 {
            logger.info("[StorageCleanup] Removed \(removedCount) audio files older than \(retentionDays) days")
        }
    }
}
