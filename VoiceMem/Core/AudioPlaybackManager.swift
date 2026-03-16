import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Playback")

/// Plays back recorded audio segments. Observable for SwiftUI binding.
@MainActor
@Observable
final class AudioPlaybackManager {
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    private(set) var isPlaying = false
    private(set) var currentFile: String?  // filename of currently playing audio
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var progress: Double {
        duration > 0 ? currentTime / duration : 0
    }

    // MARK: - Playback Control

    func play(filename: String) {
        // Stop current playback if different file
        if currentFile != filename { stop() }

        let url = AudioEncoder.fullPath(for: filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("[Playback] File not found: \(filename)")
            return
        }

        do {
            if player == nil || currentFile != filename {
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                currentFile = filename
                duration = player?.duration ?? 0
            }

            player?.play()
            isPlaying = true
            startProgressTimer()
            logger.info("[Playback] Playing \(filename)")
        } catch {
            logger.error("[Playback] Failed: \(error.localizedDescription)")
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentFile = nil
        currentTime = 0
        duration = 0
        stopProgressTimer()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let target = fraction * player.duration
        player.currentTime = target
        currentTime = target
    }

    func togglePlayPause(filename: String) {
        if isPlaying && currentFile == filename {
            pause()
        } else {
            play(filename: filename)
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopProgressTimer()
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
