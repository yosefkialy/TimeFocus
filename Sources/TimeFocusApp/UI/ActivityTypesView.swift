import FocusCore
import SwiftUI

struct ActivityTypesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("סוגי פעילות").font(.largeTitle.bold())
                        Text("קבוצות שהמודל גילה לבד מתוך השימוש שלך. תן שמות, אחד קבוצות דומות, והן ישמשו לתכנון המיקוד.")
                            .foregroundStyle(.secondary)
                        Text("בכל כרטיס מופיע על מה המודל התבסס: מילים מהטקסט שעל המסך, מכותרות החלונות ומכתובות האתרים, ואיך מודל השפה תיאר את החלונות. לחיצה על חלון מראה מה נקלט ממנו ומאפשרת להעביר אותו לסוג אחר או לסוג חדש.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                if model.learning.phase == .naming {
                    Card(title: "שלב מתן השמות", systemImage: "sparkles") {
                        Text("מתן שמות הוא לא חובה — אפשר גם להשאיר את השמות שהוצעו. כשתסיים לחץ \"סיימתי\" והמערכת תעבור למצב פעיל: היא תמשיך ללמוד ותזהה גם תוכן חדש מאותו סוג.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("סיימתי") { model.finishNaming() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if model.clusters.isEmpty {
                    Card(title: "עדיין אין סוגי פעילות", systemImage: "hourglass") {
                        Text("הלמידה רצה כשהמחשב פנוי (אחרי \(Int(model.settings.learningIdleMinutes)) דקות בלי שימוש). אפשר גם להפעיל אותה ידנית ממסך \"למידה ומודלים\".")
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(model.clusters) { c in ClusterCard(cluster: c) }
                }
                if !unassigned.isEmpty { unassignedSection }
            }
            .padding(20)
        }
        .onAppear { model.refreshEvidence() }
        .onChange(of: model.clusters) { _, _ in model.refreshEvidence() }
    }

    private var unassigned: [WindowEvidence] {
        Array((model.evidence.unassigned?.windows ?? []).filter { $0.seconds >= 60 }.prefix(12))
    }

    private var unassignedSection: some View {
        Card(title: "פעילות שעוד לא סווגה", systemImage: "questionmark.folder") {
            Text("חלונות חדשים שהמודל עוד לא בטוח לגביהם. שיוך ידני הוא האות החזק ביותר ללמידה.").font(.caption).foregroundStyle(.secondary)
            ForEach(unassigned) { w in WindowEvidenceRow(window: w) }
        }
    }
}

struct ClusterCard: View {
    @EnvironmentObject var model: AppModel
    let cluster: ActivityCluster
    /// Opens one window's details right away (snapshot renderer).
    var expandedWindowID: ContextID? = nil
    @ViewState private var name = ""
    @ViewState private var showAllWindows = false
    @FocusState private var editing: Bool

    private var evidence: ClusterEvidence? { model.evidence.clusters[cluster.id] }
    private var tint: Color { Theme.color(cluster.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(tint).frame(width: 14, height: 14)
                TextField(cluster.suggestedName ?? cluster.autoName, text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { _, now in if !now { commit() } }
                if cluster.isNew {
                    Text("חדש").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.uncertainAmber.opacity(0.25)))
                }
                Spacer()
                Text(Fmt.duration(cluster.totalSeconds)).font(.caption).foregroundStyle(.secondary)
                menu
            }
            if let s = cluster.suggestedName, !cluster.userNamed, name.isEmpty {
                Button { name = s; commit() } label: { Label("הצעת המודל: \(s)", systemImage: "wand.and.stars") }
                    .buttonStyle(.link).font(.caption)
            }
            if let d = cluster.description, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !cluster.topApps.isEmpty {
                HStack(spacing: 6) {
                    ForEach(cluster.topApps.prefix(4), id: \.self) { a in
                        Text(a).font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
            }
            if let e = evidence { ClusterEvidenceView(evidence: e, tint: tint) }
            Divider()
            windowsList
            HStack {
                Toggle("מותר תמיד", isOn: Binding(get: { model.settings.alwaysAllowedClusterIDs.contains(cluster.id) },
                                                  set: { _ in model.toggleAlwaysAllowed(cluster.id) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("פעילות שמותרת בכל בלוק מיקוד (למשל תקשורת עם הצוות)")
                Spacer()
                Button("מיקוד עכשיו (50 ד׳)") { model.startFocus([cluster.id], minutes: 50) }.controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35)))
        .onAppear { name = cluster.name ?? "" }
    }

    @ViewBuilder private var windowsList: some View {
        let windows = evidence?.windows ?? []
        if evidence != nil && windows.isEmpty {
            Text("אין כרגע חלונות בסוג הזה.").font(.caption).foregroundStyle(.secondary)
        } else if !windows.isEmpty {
            let total = evidence?.totalWindows ?? windows.count
            VStack(alignment: .leading, spacing: 7) {
                Text(total == 1 ? "חלון אחד" : total > windows.count ? "\(total) חלונות (מוצגים \(windows.count) העיקריים)" : "\(total) חלונות")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(showAllWindows ? windows : Array(windows.prefix(4))) { w in
                    WindowEvidenceRow(window: w, startExpanded: w.id == expandedWindowID)
                }
                if windows.count > 4 {
                    Button(showAllWindows ? "הצג פחות" : windows.count == 5 ? "הצג עוד חלון אחד" : "הצג עוד \(windows.count - 4) חלונות") {
                        showAllWindows.toggle()
                    }
                        .buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Section("אחד לתוך…") {
                ForEach(model.clusters.filter { $0.id != cluster.id }) { other in
                    Button(other.displayName) { model.merge(cluster.id, into: other.id) }
                }
            }
            Button("פצל לשניים") { model.split(cluster.id) }
                .help("כשסוג פעילות מערבב שני דברים שונים — המודל יחלק אותו לשתי קבוצות")
            if cluster.userNamed { Button("הסר שם") { name = ""; model.rename(cluster.id, nil) } }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (cluster.name ?? "") { model.rename(cluster.id, trimmed.isEmpty ? nil : trimmed) }
    }
}
