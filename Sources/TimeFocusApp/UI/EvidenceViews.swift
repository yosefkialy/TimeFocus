import FocusCore
import FocusML
import SwiftUI

/// Hebrew wording for the evidence the models used (the LLM itself answers in English, by design).
enum EvidenceText {
    static let categories: [String: String] = [
        "software development": "פיתוח תוכנה", "writing": "כתיבה", "studying / coursework": "לימודים",
        "reading / research": "קריאה ומחקר", "email": "דוא״ל", "chat / messaging": "צ׳אט והודעות",
        "meetings / calls": "פגישות ושיחות", "planning / management": "תכנון וניהול", "design / creative": "עיצוב ויצירה",
        "data / spreadsheets": "נתונים וגיליונות", "finance / admin": "כספים וניירת", "shopping": "קניות", "news": "חדשות",
        "social media": "רשתות חברתיות", "video / entertainment": "וידאו ובידור", "music / audio": "מוזיקה ושמע",
        "gaming": "משחקים", "system / utilities": "מערכת וכלים", "other": "אחר",
    ]

    static func category(_ c: String) -> String { categories[c] ?? c }

    static func assignment(_ w: WindowEvidence) -> String {
        switch w.assignment {
        case .user: return "שייכת אותו בעצמך"
        case .llm: return "מודל השפה שייך אותו לסוג הזה (ביטחון \(Fmt.percent(w.confidence)))"
        case .prototype: return "דומה לחלונות אחרים בסוג הזה"
        case .autoCluster: return "קובץ אוטומטית יחד עם חלונות דומים"
        case .none: return "עוד לא שויך לסוג"
        }
    }

    /// "הרבה הקלדה · בדרך כלל סביב 10:30" — the same thresholds the LLM prompt uses.
    static func behavior(_ b: BehaviorStats, typicalHour: Double?) -> String? {
        var parts: [String] = []
        if b.seconds >= 60 {
            if b.keysPerMin > 40 { parts.append("הרבה הקלדה") } else if b.keysPerMin < 3 { parts.append("כמעט בלי הקלדה") }
            if b.scrollsPerMin > 20 { parts.append("הרבה גלילה וקריאה") }
            if b.mediaFraction > 0.4 { parts.append("וידאו או שמע מתנגנים") }
        }
        if let h = typicalHour { parts.append("בדרך כלל סביב " + Fmt.minuteOfDay((Int((h * 2).rounded()) * 30) % (24 * 60))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func sources(_ s: EvidenceSources) -> String {
        var parts: [String] = []
        if s.contains(.text) { parts.append("בטקסט שעל המסך") }
        if s.contains(.title) { parts.append("בכותרת החלון") }
        if s.contains(.address) { parts.append("בכתובת האתר") }
        if s.contains(.model) { parts.append("בתיאור של המודל") }
        return parts.joined(separator: ", ")
    }

    static func termHelp(_ t: EvidenceTerm) -> String {
        let from = sources(t.sources)
        return t.windows > 1 ? "מופיע ב-\(t.windows) חלונות · \(from)" : from
    }
}

/// Keyword chips (hosts get a globe).
struct TermChips: View {
    let terms: [EvidenceTerm]
    var tint: Color = .primary

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(terms, id: \.term) { t in
                HStack(spacing: 3) {
                    if t.sources.contains(.address), t.term.contains(".") { Image(systemName: "globe").imageScale(.small) }
                    Text(t.term).lineLimit(1)
                }
                .font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.10)))
                .help(EvidenceText.termHelp(t))
            }
        }
    }
}

/// A small captioned block ("from the text on screen: …").
struct EvidenceSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// Why the model grouped these windows: words from the screen, titles and addresses, and what the LLM understood.
struct ClusterEvidenceView: View {
    let evidence: ClusterEvidence
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !evidence.textTerms.isEmpty {
                EvidenceSection(title: "מילים מהטקסט שעל המסך", symbol: "text.viewfinder") {
                    TermChips(terms: evidence.textTerms, tint: tint)
                }
            }
            if !evidence.addressTerms.isEmpty {
                EvidenceSection(title: "מכותרות החלונות ומכתובות האתרים", symbol: "link") {
                    TermChips(terms: evidence.addressTerms, tint: tint)
                }
            }
            if !evidence.descriptions.isEmpty || !evidence.categories.isEmpty {
                EvidenceSection(title: "איך המודל תיאר את החלונות", symbol: "sparkles") {
                    ForEach(evidence.descriptions, id: \.activity) { d in
                        Text(d.activity + (d.topic.map { " — \($0)" } ?? ""))
                            .font(.caption).lineLimit(1)
                            .help("\(Fmt.duration(d.seconds)) בחלונות שתוארו כך")
                    }
                    if !evidence.categories.isEmpty {
                        Text(evidence.categories.map { "\(EvidenceText.category($0.category)) \(Fmt.percent($0.share))" }
                            .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let b = EvidenceText.behavior(evidence.behavior, typicalHour: evidence.typicalHour) {
                EvidenceSection(title: "דפוס השימוש", symbol: "hand.point.up.left") {
                    Text(b).font(.caption)
                }
            }
            if evidence.textTerms.isEmpty && evidence.addressTerms.isEmpty && evidence.descriptions.isEmpty {
                Text("עדיין אין מספיק מידע על החלונות בסוג הזה — המודל יתאר אותם כשהמחשב יהיה פנוי.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One window of an activity type: what it is, the words that characterise it, and — expanded — everything the
/// app knows about it, with a way to move it to another type (a manual split).
struct WindowEvidenceRow: View {
    @EnvironmentObject var model: AppModel
    let window: WindowEvidence
    @ViewState private var expanded: Bool
    @ViewState private var askingName = false
    @ViewState private var newName = ""

    init(window: WindowEvidence, startExpanded: Bool = false) {
        self.window = window
        _expanded = ViewState(initialValue: startExpanded)
    }

    private var label: String { window.hasInformativeTitle ? window.title : window.appName }

    /// Site and a few words, so that "Claude" is no longer the only thing a window says about itself.
    private var summary: String {
        let lower = label.lowercased()
        var parts: [String] = []
        if let h = window.host, !lower.contains(h) { parts.append(h) }
        parts += window.terms.map(\.term).filter { !lower.contains($0.lowercased()) && $0 != window.host }.prefix(4)
        if parts.isEmpty, let a = window.activity { parts.append(a) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 8) {
                    AppIconView(bundleID: window.bundleID, size: 16).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.callout).lineLimit(1)
                        if !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 6)
                    Text(Fmt.duration(window.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "הסתר פרטים" : "מה המודל ראה בחלון הזה")
            if expanded { details.padding(.leading, 24).transition(.opacity) }
        }
        .contextMenu { moveItems }
        .alert("סוג פעילות חדש", isPresented: $askingName) {
            TextField("שם", text: $newName)
            Button("צור והעבר") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                model.moveToNewCluster(window.id, name: name.isEmpty ? String(label.prefix(40)) : name)
            }
            Button("ביטול", role: .cancel) {}
        } message: {
            Text("„\(label)“ יעבור לסוג פעילות חדש. המודל ילמד ממנו בריצת הלמידה הבאה ויזהה חלונות דומים.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !window.hasInformativeTitle && window.host == nil { // the window's identity is then just app + title
                Label("לחלון הזה אין כותרת שמתארת את התוכן, אז כל מה שנעשה בו נספר כחלון אחד. המילים מתעדכנות לפי הטקסט שהופיע בו לאחרונה.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let host = window.host {
                EvidenceSection(title: "כתובת", symbol: "globe") {
                    Text(host + (window.urlPath ?? "")).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if !window.terms.isEmpty {
                EvidenceSection(title: "מילים שמאפיינות את החלון", symbol: "text.magnifyingglass") {
                    TermChips(terms: window.terms)
                }
            }
            if let activity = window.activity {
                EvidenceSection(title: "המודל תיאר", symbol: "sparkles") {
                    Text(activity + (window.topic.map { " — \($0)" } ?? "")
                         + (window.category.map { " (\(EvidenceText.category($0)))" } ?? ""))
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            EvidenceSection(title: "איך שויך", symbol: "point.3.connected.trianglepath.dotted") {
                Text(EvidenceText.assignment(window)).font(.caption)
            }
            if window.textLines.isEmpty {
                Text("לא נקלט טקסט מהחלון הזה.").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(window.textLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 2)
                } label: {
                    Text("הטקסט שנקלט מהחלון").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Menu { moveItems } label: {
                Label(window.clusterID == nil ? "שייך לסוג פעילות" : "העבר לסוג אחר", systemImage: "arrow.triangle.swap")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .help("שיוך ידני הוא האות החזק ביותר ללמידה")
        }
    }

    @ViewBuilder private var moveItems: some View {
        ForEach(model.clusters.filter { $0.id != window.clusterID }) { c in
            Button(c.displayName) { model.move(window.id, to: c.id) }
        }
        Divider()
        Button("סוג פעילות חדש…") { newName = ""; askingName = true }
    }
}
