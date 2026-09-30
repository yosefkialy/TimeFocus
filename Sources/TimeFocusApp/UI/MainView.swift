import Charts
import FocusCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedTab }, set: { if let t = $0 { model.selectedTab = t } })) {
                ForEach(MainTab.allCases) { tab in
                    // .tag must stay the outermost modifier: a modifier after it (such as .badge) hides the tag from
                    // the List, so no row can be selected and the sidebar ignores clicks.
                    Label(tab.title, systemImage: tab.symbol)
                        .badge(tab == .activities && model.learning.phase == .naming ? Text("!") : nil)
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch model.selectedTab {
                case .today: TodayView()
                case .timeline: TimelineView()
                case .activities: ActivityTypesView()
                case .learning: LearningView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.refreshStats(); model.refreshEnvironment() }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.settings.trackingEnabled ? Theme.focusGreen : .gray).frame(width: 8, height: 8)
                Text(model.settings.trackingEnabled ? "מעקב פעיל" : "מעקב מושהה").font(.caption)
            }
            Text("כל הנתונים נשמרים רק על המחשב הזה").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

// MARK: - Today

struct TodayView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = model.startupError {
                    Card(title: "שגיאה בהפעלה", systemImage: "exclamationmark.octagon") { Text(err).textSelection(.enabled) }
                }
                if model.learning.phase == .collecting { learningBanner }
                if model.learning.phase == .naming { namingBanner }
                LiveStatusCard()
                PlanEditor()
                statsSection
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting).font(.largeTitle.bold())
            Text(Fmt.day.string(from: Date())).foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "בוקר טוב"
        case 12..<17: return "צהריים טובים"
        case 17..<22: return "ערב טוב"
        default: return "לילה טוב"
        }
    }

    private var learningBanner: some View {
        Card(title: "שלב הלמידה", systemImage: "brain.head.profile") {
            Text("TimeFocus לומד בשקט איך אתה משתמש במחשב ומקבץ את הפעילות שלך לסוגים. אחרי \(model.learning.readiness.requiredDays) ימי שימוש (~\(Int(model.learning.readiness.requiredHours)) שעות) תתבקש לתת שמות לסוגי הפעילות — ואז אפשר לתכנן מיקוד.")
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: model.learning.readiness.fraction) {
                Text("\(model.learning.readiness.daysWithData) / \(model.learning.readiness.requiredDays) ימים · \(String(format: "%.1f", model.learning.readiness.hoursTracked)) / \(Int(model.learning.readiness.requiredHours)) שעות")
                    .font(.caption)
            }
            if !model.clusters.isEmpty {
                HStack {
                    Text("כבר זוהו \(model.clusters.count) סוגי פעילות ראשוניים.").font(.callout)
                    Spacer()
                    Button("יש לי מספיק נתונים — בוא נמשיך") { model.startNamingNow(); model.selectedTab = .activities }
                }
            }
        }
    }

    private var namingBanner: some View {
        Card(title: "הגיע הזמן לתת שמות", systemImage: "sparkles") {
            HStack {
                Text("זוהו \(model.clusters.count) סוגי פעילות. תן להם שמות (לא חובה) כדי שיהיה קל לתכנן מיקוד.")
                Spacer()
                Button("לסוגי הפעילות") { model.selectedTab = .activities }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var statsSection: some View {
        Card(title: "היום במספרים", systemImage: "chart.pie") {
            HStack(spacing: 10) {
                StatTile(title: "זמן פעיל", value: Fmt.duration(model.today.tracked))
                StatTile(title: "במיקוד", value: Fmt.duration(model.today.onTrack), color: Theme.focusGreen)
                StatTile(title: "סטייה", value: Fmt.duration(model.today.offTrack), color: Theme.driftRed)
                StatTile(title: "סטיות", value: "\(model.today.episodes)", subtitle: "חזרת \(model.today.returned) פעמים", color: Theme.uncertainAmber)
                StatTile(title: "יחס מיקוד", value: Fmt.percent(model.today.focusRatio), color: Theme.accent)
            }
            if model.today.perCluster.isEmpty {
                Text("עדיין אין מספיק נתונים להיום.").foregroundStyle(.secondary)
            } else {
                Chart(model.today.perCluster) { item in
                    BarMark(x: .value("דקות", item.seconds / 60), y: .value("פעילות", model.clusterName(item.clusterID)))
                        .foregroundStyle(Theme.color(for: model.cluster(item.clusterID)))
                        .annotation(position: .trailing) { Text(Fmt.duration(item.seconds)).font(.caption2).foregroundStyle(.secondary) }
                }
                .chartXAxisLabel("דקות")
                .frame(height: CGFloat(max(120, model.today.perCluster.count * 30)))
            }
        }
    }
}

struct LiveStatusCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let st = model.status
        Card(title: "עכשיו", systemImage: Theme.verdictSymbol(st.verdict, throttling: st.throttleLevel > 0.01)) {
            HStack(alignment: .top, spacing: 14) {
                if !st.bundleID.isEmpty { AppIconView(bundleID: st.bundleID, size: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(st.away ? "לא פעיל" : st.appName).font(.title3.bold())
                    if !st.title.isEmpty { Text(st.title).foregroundStyle(.secondary).lineLimit(2) }
                    HStack(spacing: 8) {
                        if let id = st.activityID { ClusterChip(name: model.clusterName(id), color: Theme.color(for: model.cluster(id))) }
                        Text(Theme.verdictLabel(st.verdict)).font(.callout.bold()).foregroundStyle(Theme.verdictColor(st.verdict))
                        if st.verdict == .offTrack { Text("· \(Fmt.clock(st.driftSeconds))").monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let f = st.focus {
                        Text("מיקוד עד \(Fmt.time.string(from: f.end))").font(.caption).foregroundStyle(.secondary)
                        FlowChips(ids: Array(f.clusterIDs), model: model)
                        if f.isManual { Button("סיים מיקוד") { model.endFocus() }.controlSize(.small) }
                    } else {
                        QuickFocusMenu()
                    }
                    if st.throttleLevel > 0.01 {
                        HStack {
                            Image(systemName: "tortoise.fill").foregroundStyle(Theme.driftRed)
                            Text("האטה \(Fmt.percent(st.throttleLevel))").monospacedDigit()
                            Button("עצירת חירום") { model.emergencyStop() }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Plan editor

struct PlanEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "התוכנית להיום", systemImage: "calendar.day.timeline.leading") {
            if model.clusters.isEmpty {
                Text("אחרי שהאפליקציה תזהה סוגי פעילות, תוכל לבחור כאן על מה להתמקד — לכל היום או לפי שעות.")
                    .foregroundStyle(.secondary)
            } else {
                if model.plan.blocks.isEmpty {
                    Text("עדיין לא נקבע מיקוד להיום. הוסף בלוק זמן ובחר על אילו סוגי פעילות להתמקד בו.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.plan.blocks) { block in
                    BlockRow(block: block, onChange: { updated in replace(updated) }, onDelete: { delete(block) })
                    Divider()
                }
                if hasOverlap { Label("יש בלוקים חופפים — הבלוק המוקדם יותר קובע.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption) }
                HStack {
                    Button { addBlock() } label: { Label("הוסף בלוק", systemImage: "plus") }
                    Button { allDay() } label: { Label("מיקוד עד סוף היום", systemImage: "sun.max") }
                    Button { model.copyPlanFromPreviousDay() } label: { Label("העתק מהתוכנית הקודמת", systemImage: "doc.on.doc") }
                    Spacer()
                    if !model.plan.blocks.isEmpty {
                        Button(role: .destructive) { model.savePlan(DayPlan(day: Date().dayKey)) } label: { Text("נקה") }
                    }
                }
            }
        }
    }

    private var hasOverlap: Bool {
        let b = model.plan.blocks.sorted { $0.startMinute < $1.startMinute }
        return zip(b, b.dropFirst()).contains { $0.endMinute > $1.startMinute }
    }

    private func replace(_ block: FocusBlock) {
        var p = model.plan
        if let i = p.blocks.firstIndex(where: { $0.id == block.id }) { p.blocks[i] = block }
        p.blocks.sort { $0.startMinute < $1.startMinute }
        model.savePlan(p)
    }

    private func delete(_ block: FocusBlock) {
        var p = model.plan
        p.blocks.removeAll { $0.id == block.id }
        model.savePlan(p)
    }

    private func addBlock() {
        var p = model.plan
        p.day = Date().dayKey
        let nowMin = (Date().minuteOfDay / 15) * 15
        let start = max(nowMin, p.blocks.map(\.endMinute).max() ?? 0)
        let clusters = p.blocks.last?.clusterIDs ?? (model.clusters.first.map { [$0.id] } ?? [])
        p.blocks.append(FocusBlock(startMinute: min(start, 23 * 60), endMinute: min(start + 90, 24 * 60 - 1), clusterIDs: clusters))
        model.savePlan(p)
    }

    private func allDay() {
        var p = model.plan
        p.day = Date().dayKey
        let start = (Date().minuteOfDay / 5) * 5
        let clusters = p.blocks.last?.clusterIDs ?? (model.clusters.first.map { [$0.id] } ?? [])
        p.blocks = p.blocks.filter { $0.endMinute <= start }
        p.blocks.append(FocusBlock(startMinute: start, endMinute: 24 * 60 - 1, clusterIDs: clusters))
        model.savePlan(p)
    }
}

struct BlockRow: View {
    @EnvironmentObject var model: AppModel
    let block: FocusBlock
    var onChange: (FocusBlock) -> Void
    var onDelete: () -> Void

    private func date(_ minute: Int) -> Date { Date().startOfDay.addingTimeInterval(Double(minute) * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DatePicker("מ־", selection: Binding(get: { date(block.startMinute) }, set: { d in
                    var b = block; b.startMinute = d.minuteOfDay
                    if b.endMinute <= b.startMinute { b.endMinute = min(b.startMinute + 30, 24 * 60 - 1) }
                    onChange(b)
                }), displayedComponents: .hourAndMinute)
                .fixedSize()
                DatePicker("עד", selection: Binding(get: { date(block.endMinute) }, set: { d in
                    var b = block; b.endMinute = max(d.minuteOfDay, b.startMinute + 5); onChange(b)
                }), displayedComponents: .hourAndMinute)
                .fixedSize()
                Text("(\(Fmt.duration(Double(block.durationMinutes) * 60)))").font(.caption).foregroundStyle(.secondary)
                if block.contains(minute: Date().minuteOfDay) {
                    Text("עכשיו").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent.opacity(0.18))).foregroundStyle(Theme.accent)
                }
                Spacer()
                TextField("הערה (לא חובה)", text: Binding(get: { block.note }, set: { var b = block; b.note = $0; onChange(b) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            FlowLayout(spacing: 6) {
                ForEach(model.clusters) { c in
                    let selected = block.clusterIDs.contains(c.id)
                    Button {
                        var b = block
                        if selected { b.clusterIDs.removeAll { $0 == c.id } } else { b.clusterIDs.append(c.id) }
                        onChange(b)
                    } label: { ClusterChip(name: c.displayName, color: Theme.color(c.color), selected: selected) }
                    .buttonStyle(.plain)
                }
            }
            if block.clusterIDs.isEmpty {
                Text("בחר לפחות סוג פעילות אחד — אחרת כל פעילות תיחשב סטייה.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
