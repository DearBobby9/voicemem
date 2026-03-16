import Foundation

/// Represents a VAD-detected speech segment before transcription.
struct AudioSegment: Sendable {
    let samples: [Float]          // PCM 16kHz mono
    let timestampStart: Int64     // Unix epoch ms
    let timestampEnd: Int64       // Unix epoch ms

    var durationMs: Int64 {
        timestampEnd - timestampStart
    }

    var durationSeconds: Double {
        Double(durationMs) / 1000.0
    }
}
