import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioEncoder")

/// Encodes audio segments to WAV files for storage and WhisperKit transcription.
enum AudioEncoder {
    static let audioDir: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceMem/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }()

    /// Encode an AudioSegment to a WAV file at the given sample rate. Returns the filename.
    static func encode(segment: AudioSegment, sampleRate: Double = 48000) throws -> String {
        let filename = "\(segment.timestampStart).wav"
        let fileURL = audioDir.appendingPathComponent(filename)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioEncoderError.formatCreationFailed
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(segment.samples.count)
        ) else {
            throw AudioEncoderError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(segment.samples.count)
        // Bulk copy instead of per-sample loop
        segment.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }

        // Write as WAV (LinearPCM) — WhisperKit handles resampling internally
        let wavSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file = try AVAudioFile(forWriting: fileURL, settings: wavSettings)
        try file.write(from: buffer)

        logger.info("[AudioEncoder] Encoded \(segment.durationMs)ms → \(filename)")
        return filename
    }

    /// Full path for a relative audio filename.
    static func fullPath(for relativePath: String) -> URL {
        audioDir.appendingPathComponent(relativePath)
    }

    /// Full path for an AudioSegment's WAV file.
    static func fullPath(for segment: AudioSegment) -> URL {
        audioDir.appendingPathComponent("\(segment.timestampStart).wav")
    }

    /// Total size of all audio files in bytes.
    static func totalStorageBytes() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: audioDir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

enum AudioEncoderError: LocalizedError {
    case formatCreationFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: "Failed to create audio format"
        case .bufferCreationFailed: "Failed to create audio buffer"
        }
    }
}
