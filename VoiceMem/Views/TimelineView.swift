import SwiftUI

/// Dayflow-style vertical timeline — shows 15-minute summary blocks.
struct TimelineView: View {
    let pipeline: PipelineCoordinator

    @State private var summaries: [Summary] = []
    @State private var selectedDate = Date()
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Timeline
            if summaries.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
        .frame(minWidth: 380, minHeight: 500)
        .onAppear { loadSummaries(); startRefreshTimer() }
        .onDisappear { refreshTimer?.invalidate() }
        .onChange(of: selectedDate) { _, _ in loadSummaries() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("VoiceMem")
                .font(.title2.bold())

            Spacer()

            // Date picker
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)

            // Stats
            Text("\(pipeline.todayCount) 条")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .padding()
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(summaries) { summary in
                    TimelineBlock(summary: summary)
                }
            }
            .padding()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("今天还没有语音记录")
                .foregroundStyle(.secondary)
            if !pipeline.isRunning {
                Text("点击菜单栏图标开始录制")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    private func loadSummaries() {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: selectedDate)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        let startMs = Int64(startOfDay.timeIntervalSince1970 * 1000)
        let endMs = Int64(endOfDay.timeIntervalSince1970 * 1000)

        summaries = (try? pipeline.database.summariesInRange(start: startMs, end: endMs)) ?? []
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            loadSummaries()
        }
    }
}

// MARK: - Timeline Block

struct TimelineBlock: View {
    let summary: Summary

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Time label
            HStack(alignment: .top) {
                Text(timeLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)

                // Vertical timeline line
                VStack {
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2)
                }

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.displayText)
                        .font(.callout)
                        .lineLimit(isExpanded ? nil : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Label("\(summary.transcriptionCount)", systemImage: "text.bubble")
                        if summary.summaryText != nil {
                            Label("AI", systemImage: "sparkles")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { isExpanded.toggle() }
            }
        }
    }

    // I5: static formatter to avoid per-render allocation
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: Double(summary.windowStart) / 1000)
        return Self.timeFormatter.string(from: date)
    }
}
