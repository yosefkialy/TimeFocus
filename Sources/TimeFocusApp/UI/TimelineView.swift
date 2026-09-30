import Charts
import FocusCore
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var day: Date

    init(day: Date = Date().startOfDay) { _day = ViewState(initialValue: day) }
    @ViewState private var segments: [SegmentRecord] = []
    @ViewState private var episodes: [DriftEpisode] = []

    private struct Row: Identifiable {
        let id: Int64
        let start: Date
        let end: Date
        let lane: String
        let color: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { day = day.addingTimeInterval(-86400); load() } label: { Image(systemName: "chevron.right") }
                Text(Fmt.day.string(from: day)).font(.title2.bold())
                Button { day = day.addingTimeInterval(86400); load() } label: { Image(systemName: "chevron.left") }
                    .disabled(day >= Date().startOfDay)
                Spacer()
                Button("היום") { day = Date().startOfDay; load() }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }
            }
            if segments.isEmpty {
                Spacer()
                Text("אין נתונים ליום הזה.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                chart
                legend
                list
            }
        }
        .padding(20)
        .onAppear { load() }
    }

    private func load() {
        guard let store = model.engine?.uiStore else { return }
        segments = (try? store.segments(from: day, to: day.addingTimeInterval(86400))) ?? []
        episodes = (try? store.episodes(from: day, to: day.addingTimeInterval(86400))) ?? []
    }

    private var rows: [Row] {
        var out: [Row] = []
        for s in segments where s.end.timeIntervalSince(s.start) >= 1 {
            let cid = s.contextClusterID ?? s.clusterID
            out.append(Row(id: s.id * 2, start: s.start, end: s.end, lane: "פעילות", color: Theme.color(for: model.cluster(cid))))
            let fc: Color
            switch s.focusState {
            case .onTrack: fc = Theme.focusGreen
            case .offTrack: fc = Theme.driftRed
            case .uncertain: fc = Theme.uncertainAmber
            case .neutral: fc = .gray.opacity(0.4)
            case .none: fc = .clear
            }
            out.append(Row(id: s.id * 2 + 1, start: s.start, end: s.end, lane: "מיקוד", color: fc))
        }
        return out
    }

    private var chart: some View {
        let first = segments.first?.start ?? day
        let last = segments.last?.end ?? day.addingTimeInterval(3600)
        return Chart(rows) { r in
            RectangleMark(xStart: .value("התחלה", r.start), xEnd: .value("סוף", r.end), y: .value("שורה", r.lane), height: 26)
                .foregroundStyle(r.color)
        }
        .chartXScale(domain: first.addingTimeInterval(-600)...last.addingTimeInterval(600))
        .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
        .frame(height: 110)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: 14) {
            FlowLayout(spacing: 6) {
                ForEach(model.clusters) { c in ClusterChip(name: c.displayName, color: Theme.color(c.color)) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("במיקוד", systemImage: "square.fill").foregroundStyle(Theme.focusGreen).font(.caption)
                Label("סטייה", systemImage: "square.fill").foregroundStyle(Theme.driftRed).font(.caption)
            }
            .fixedSize()
        }
    }

    private var list: some View {
        List {
            Section("\(segments.count) קטעים · \(episodes.count) סטיות") {
                ForEach(segments.reversed().filter { $0.activeSeconds >= 5 }) { s in
                    SegmentRow(segment: s)
                }
            }
        }
        .listStyle(.inset)
    }
}

struct SegmentRow: View {
    @EnvironmentObject var model: AppModel
    let segment: SegmentRecord

    var body: some View {
        let cid = segment.contextClusterID ?? segment.clusterID
        HStack(spacing: 10) {
            Text("\(Fmt.time.string(from: segment.start))–\(Fmt.time.string(from: segment.end))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            AppIconView(bundleID: segment.bundleID, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.title.isEmpty ? segment.appName : segment.title).lineLimit(1)
                Text([segment.appName, segment.host].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if segment.throttleMax > 0.01 {
                Label(Fmt.percent(segment.throttleMax), systemImage: "tortoise.fill").font(.caption).foregroundStyle(Theme.driftRed)
            }
            Text(Fmt.duration(segment.activeSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Section("שייך לסוג פעילות") {
                    ForEach(model.clusters) { c in
                        Button(c.displayName) { model.assign(segment.contextID, to: c.id) }
                    }
                }
            } label: {
                ClusterChip(name: model.clusterName(cid), color: Theme.color(for: model.cluster(cid)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("לחץ כדי לתקן את הסיווג — זה מאמן את המודל")
        }
    }
}
