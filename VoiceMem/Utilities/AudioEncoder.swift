import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "AudioEncoder")

/// Encodes audio segments to FLAC/CAF files for storage.
enum AudioEncoder {
    private static let audioDir: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("VoiceMem/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }()

    /// Encode an AudioSegment to a CAF file. Returns the relative path.
    static func encode(segment: AudioSegment) throws -> String {
        let filename = "\(segment.timestampStart).caf"
        let fileURL = audioDir.appendingPathComponent(filename)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
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
        let channelData = buffer.floatChannelData![0]
        for (i, sample) in segment.samples.enumerated() {
            channelData[i] = sample
        }

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try file.write(from: buffer)

        logger.info("[AudioEncoder] Encoded \(segment.durationMs)ms → \(filename)")
        return filename
    }

    /// Full path for a relative audio filename.
    static func fullPath(for relativePath: String) -> URL {
        audioDir.appendingPathComponent(relativePath)
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
