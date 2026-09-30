import AppKit
import FocusCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.hasAccessibility { permissionWarning }
            focusSection
            currentActivity
            if model.status.throttleLevel > 0.01 { throttleSection }
            todaySummary
            learningLine
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "scope").foregroundStyle(Theme.accent).font(.title3.bold())
            Text("TimeFocus").font(.title3.bold())
            Spacer()
            Text(Theme.verdictLabel(model.status.verdict))
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.verdictColor(model.status.verdict).opacity(0.18)))
                .foregroundStyle(Theme.verdictColor(model.status.verdict))
        }
    }

    private var permissionWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("נדרשת הרשאת נגישות כדי לזהות חלונות ותוכן.").font(.callout)
                Button("פתח הגדרות הרשאות") { model.openOnboarding?() }.controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }

    @ViewBuilder
    private var focusSection: some View {
        if let f = model.status.focus {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(f.isManual ? "מיקוד עכשיו" : "בלוק מיקוד").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("עד \(Fmt.time.string(from: f.end))").font(.caption).foregroundStyle(.secondary)
                }
                FlowChips(ids: Array(f.clusterIDs), model: model)
                ProgressView(value: min(1, max(0, Date().timeIntervalSince(f.start) / max(f.end.timeIntervalSince(f.start), 1))))
                    .tint(Theme.accent)
                if f.isManual {
                    Button("סיים מיקוד") { model.endFocus() }.controlSize(.small)
                }
            }
        } else {
            HStack {
                Text("אין מיקוד פעיל כרגע").foregroundStyle(.secondary)
                Spacer()
                QuickFocusMenu()
            }
        }
        if let until = model.status.breakUntil, until > Date() {
            HStack {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.brown)
                Text("בהפסקה עד \(Fmt.time.string(from: until))")
                Spacer()
                Button("סיים הפסקה") { model.endBreak() }.controlSize(.small)
            }
        }
        if let paused = model.status.interventionsPausedUntil, paused > Date() {
            HStack {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                Text("התערבויות מושהות עד \(Fmt.time.string(from: paused))").font(.callout)
                Spacer()
                Button("חדש") { model.resumeInterventions() }.controlSize(.small)
            }
        }
    }

    private var currentActivity: some View {
        HStack(alignment: .top, spacing: 10) {
            if !model.status.bundleID.isEmpty { AppIconView(bundleID: model.status.bundleID, size: 28) }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.away ? "לא פעיל כרגע" : model.status.appName).font(.callout.bold())
                if !model.status.title.isEmpty {
                    Text(model.status.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let id = model.status.activityID {
                    HStack(spacing: 6) {
                        ClusterChip(name: model.clusterName(id), color: Theme.color(for: model.cluster(id)))
                        Text(Fmt.percent(model.status.confidence)).font(.caption2).foregroundStyle(.secondary)
                        if model.status.source == .model && model.status.novelty > 0.5 {
                            Text("חדש").font(.caption2.bold()).foregroundStyle(Theme.uncertainAmber)
                        }
                    }
                } else if model.status.isPrivate {
                    Text("חלון פרטי — לא נאסף תוכן").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    private var throttleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "tortoise.fill").foregroundStyle(Theme.driftRed)
                Text("האטה פעילה על \(model.status.appName)").font(.callout.bold())
                Spacer()
                Text(Fmt.percent(model.status.throttleLevel)).monospacedDigit()
            }
            ProgressView(value: model.status.throttleLevel).tint(Theme.driftRed)
            HStack {
                Button { model.backToFocus() } label: { Label("חזרה למיקוד", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("הפסקה (\(model.status.breaksLeft))") { model.takeBreak() }.disabled(model.status.breaksLeft == 0)
                Spacer()
                Button("עצירת חירום") { model.emergencyStop() }.foregroundStyle(Theme.driftRed)
                    .help("מבטל מיד את ההאטה ומשהה התערבויות לשעה (⌃⌥⌘.)")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.driftRed.opacity(0.08)))
    }

    private var todaySummary: some View {
        HStack(spacing: 8) {
            StatTile(title: "במיקוד היום", value: Fmt.duration(model.today.onTrack), color: Theme.focusGreen)
            StatTile(title: "סטיות", value: "\(model.today.episodes)", subtitle: Fmt.duration(model.today.offTrack), color: Theme.driftRed)
            StatTile(title: "יחס מיקוד", value: Fmt.percent(model.today.focusRatio), color: Theme.accent)
        }
    }

    @ViewBuilder
    private var learningLine: some View {
        switch model.learning.phase {
        case .collecting:
            VStack(alignment: .leading, spacing: 4) {
                Text("לומד את ההרגלים שלך… יום \(model.learning.readiness.daysWithData) מתוך \(model.learning.readiness.requiredDays)")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: model.learning.readiness.fraction)
            }
        case .naming:
            Button { model.openMainWindow?(.activities) } label: {
                Label("מוכן! תן שמות לסוגי הפעילות", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
        case .active:
            if model.learning.running {
                Label("לומד ברקע (המחשב פנוי)…", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("לוח בקרה") { model.openMainWindow?(nil) }
            Spacer()
            Button(model.settings.trackingEnabled ? "השהה מעקב" : "חדש מעקב") { model.setTracking(!model.settings.trackingEnabled) }
            Button("יציאה") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

/// Menu to start an immediate focus session on one activity type for a chosen duration.
struct QuickFocusMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            if model.clusters.isEmpty {
                Text("עדיין אין סוגי פעילות — האפליקציה לומדת")
            }
            ForEach(model.clusters) { c in
                Menu(c.displayName) {
                    ForEach([25, 50, 90, 120], id: \.self) { m in
                        Button("\(m) דקות") { model.startFocus([c.id], minutes: Double(m)) }
                    }
                }
            }
        } label: {
            Label("התחל מיקוד", systemImage: "play.fill")
        }
        .fixedSize()
        .disabled(model.clusters.isEmpty)
    }
}

struct FlowChips: View {
    let ids: [ClusterID]
    let model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(ids.sorted(), id: \.self) { id in
                ClusterChip(name: model.clusterName(id), color: Theme.color(for: model.cluster(id)))
            }
        }
    }
}
