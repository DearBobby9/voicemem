import Foundation

/// A segment currently being transcribed — shown as "转录中..." in the timeline.
struct PendingSegment: Identifiable {
    let id = UUID()
    let timestampStart: Int64
    let timestampEnd: Int64
    let durationMs: Int64
}
