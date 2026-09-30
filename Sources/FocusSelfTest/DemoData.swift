import FocusCore
import FocusML
import Foundation

/// Generates a realistic multi-day demo database (Hebrew/English activity) and runs the real learning pipeline on it.
/// Used for UI snapshots and manual exploration:  FocusSelfTest --make-demo <supportDir>
enum DemoData {
    struct Kind {
        let name: String
        let contexts: [(bundle: String, app: String, title: String, host: String?, text: String)]
        let behavior: BehaviorStats
    }

    static let kinds: [Kind] = [
        Kind(name: "עבודה", contexts: [
            ("com.microsoft.VSCode", "Code", "FocusEngine.swift — time_focus", nil, "func monitor(_ monitor: ActivityMonitor, didCapture snap: ActivitySnapshot) let classification = classifier.classify"),
            ("com.microsoft.VSCode", "Code", "api.py — backend-service", nil, "def create_order(request): session.commit() return JSONResponse status_code 201"),
            ("com.apple.Terminal", "Terminal", "zsh — time_focus", nil, "swift build error: cannot find type in scope git status modified"),
            ("com.google.Chrome", "Google Chrome", "Pull request #42 · acme/backend", "github.com", "Files changed Review requested Merge pull request Checks passed"),
            ("com.google.Chrome", "Google Chrome", "swift - How to observe window title changes with AXObserver - Stack Overflow", "stackoverflow.com", "AXObserverCreate kAXTitleChangedNotification answer accepted"),
            ("com.google.Chrome", "Google Chrome", "PROJ-1234 Fix login timeout - Jira", "acme.atlassian.net", "Sprint board In progress Assignee Story points"),
            ("com.tinyspeck.slackmacgap", "Slack", "#dev-team - Acme", nil, "deploy to staging finished code review standup notes"),
            // a chat app whose window title never changes: only its text tells work from study
            ("com.anthropic.claudefordesktop", "Claude", "Claude", nil,
             "Claude is responding\nThinking some more…\nSessions\nDeploy the backend API to staging and fix the failing migration\nThe migration fails on staging because an index is missing"),
        ], behavior: BehaviorStats(seconds: 600, keys: 700, clicks: 70, scrolls: 90, moves: 2800)),
        Kind(name: "לימודים", contexts: [
            ("com.google.Chrome", "Google Chrome", "אלגברה לינארית 1 - הרצאה 3: מרחבים וקטוריים", "moodle.tau.ac.il", "הגדרה: מרחב וקטורי מעל שדה F הוא קבוצה V עם פעולות חיבור וכפל בסקלר"),
            ("com.google.Chrome", "Google Chrome", "אלגברה לינארית 1 - תרגול 4: בסיס ומימד", "moodle.tau.ac.il", "משפט: כל שתי קבוצות פורשות בלתי תלויות הן באותו גודל - מימד המרחב"),
            ("com.apple.Preview", "Preview", "תרגיל בית 4 - אלגברה לינארית.pdf", nil, "שאלה 1: הוכיחו כי הקבוצה הבאה היא תת-מרחב. שאלה 2: מצאו בסיס"),
            ("com.google.Chrome", "Google Chrome", "MIT 18.06 Linear Algebra Lecture 5: Transposes, Permutations, Spaces", "youtube.com", "Gilbert Strang vector spaces subspaces column space lecture notes"),
            ("notion.id", "Notion", "סיכומים - אלגברה לינארית", nil, "תלות לינארית פרישה בסיס מימד מטריצה הפיכה דטרמיננטה"),
            ("com.anthropic.claudefordesktop", "Claude", "Claude", nil,
             "Claude is responding\nThinking some more…\nSessions\nעזרה בתרגיל באלגברה לינארית: ערכים עצמיים של מטריצה\nאיך מוצאים ערכים עצמיים של מטריצה סימטרית"),
        ], behavior: BehaviorStats(seconds: 600, keys: 120, clicks: 45, scrolls: 380, moves: 2400)),
        Kind(name: "תקשורת ומיילים", contexts: [
            ("com.google.Chrome", "Google Chrome", "Inbox - Gmail", "mail.google.com", "Meeting invitation Invoice attached Re: project timeline"),
            ("net.whatsapp.WhatsApp", "WhatsApp", "WhatsApp", nil, "משפחה: מה שלומכם? אני: בסדר, מגיע בערב"),
            ("com.apple.mail", "Mail", "Inbox — iCloud", nil, "חשבונית מס קבלה הזמנה אושרה"),
        ], behavior: BehaviorStats(seconds: 600, keys: 300, clicks: 110, scrolls: 160, moves: 2200)),
        Kind(name: "בידור", contexts: [
            ("com.google.Chrome", "Google Chrome", "Funny cats compilation 2026 - YouTube", "youtube.com", "Subscribe 1.2M views Up next cats fails compilation"),
            ("com.google.Chrome", "Google Chrome", "Best football goals of the season - YouTube", "youtube.com", "highlights goals 4K Up next"),
            ("com.google.Chrome", "Google Chrome", "The Crown | Netflix", "netflix.com", "Season 2 Episode 3 Continue watching"),
        ], behavior: BehaviorStats(seconds: 600, keys: 4, clicks: 8, scrolls: 25, moves: 300, mediaSeconds: 560)),
        Kind(name: "רשתות חברתיות", contexts: [
            ("com.google.Chrome", "Google Chrome", "Facebook", "facebook.com", "News Feed Reels Friends Marketplace Like Comment Share"),
            ("com.google.Chrome", "Google Chrome", "Instagram", "instagram.com", "Stories Reels Explore likes follow"),
            ("com.google.Chrome", "Google Chrome", "Home / X", "x.com", "For you Following trending posts repost"),
        ], behavior: BehaviorStats(seconds: 600, keys: 60, clicks: 80, scrolls: 750, moves: 1900)),
        Kind(name: "חדשות", contexts: [
            ("com.google.Chrome", "Google Chrome", "ynet - חדשות, כלכלה, ספורט ובריאות", "ynet.co.il", "מבזקים חדשות היום פוליטיקה כלכלה ספורט"),
            ("com.google.Chrome", "Google Chrome", "הארץ - חדשות", "haaretz.co.il", "כותרות דעות כלכלה עולם"),
        ], behavior: BehaviorStats(seconds: 600, keys: 10, clicks: 30, scrolls: 420, moves: 1500)),
    ]

    static func make(at dir: URL) async throws {
        try? FileManager.default.removeItem(at: dir)
        let paths = AppPaths(support: dir)
        try? FileManager.default.removeItem(at: paths.models)
        try FileManager.default.createSymbolicLink(at: paths.models, withDestinationURL: AppPaths.default.models)
        try? FileManager.default.createSymbolicLink(at: paths.runtime, withDestinationURL: AppPaths.default.runtime)
        let store = try Store(url: paths.database)
        var rng = SeededRandom(seed: 99)
        var ctxIDs: [[ContextID]] = []
        // several variants per window (next lecture, another PR, another video…) like real usage produces
        func variant(_ title: String, _ v: Int, app: String) -> String {
            guard v > 0, title != app else { return title } // a static title stays the same (a new conversation)
            if let r = title.range(of: #"\d+"#, options: .regularExpression), let n = Int(title[r]) {
                return title.replacingCharacters(in: r, with: String(n + v))
            }
            return title + " (\(v + 1))"
        }
        for (ki, k) in kinds.enumerated() {
            var ids: [ContextID] = []
            for (ci, c) in k.contexts.enumerated() {
                for v in 0..<4 {
                    let key = "demo-\(ki)-\(ci)-\(v)"
                    let rec = try store.insertContext(key: key, bundleID: c.bundle, appName: c.app, title: variant(c.title, v, app: c.app),
                                                      host: c.host, urlPath: c.host.map { _ in "/view/\(v)" }, docPath: nil,
                                                      isPrivate: false, now: Date())
                    try store.mergeContextText(id: rec.id, text: c.text, now: Date())
                    ids.append(rec.id)
                }
            }
            ctxIDs.append(ids)
        }
        // 4 days of sessions: mostly work/study with some drifts
        let cal = Calendar.current
        let today = Date().startOfDay
        for dayOffset in (0...3).reversed() {
            let day = today.addingTimeInterval(-Double(dayOffset) * 86400)
            var t = day.addingTimeInterval(8.5 * 3600)
            let end = dayOffset == 0 ? min(Date(), day.addingTimeInterval(19 * 3600)) : day.addingTimeInterval(19 * 3600)
            var focusKind = 0
            while t < end {
                let hour = cal.component(.hour, from: t)
                focusKind = hour < 13 ? 0 : (hour < 16 ? 1 : (rng.uniform() < 0.5 ? 0 : 1))
                let r = rng.uniform()
                let kind = r < 0.68 ? focusKind : (r < 0.8 ? 2 : (r < 0.9 ? 3 : (r < 0.96 ? 4 : 5)))
                let ids = ctxIDs[kind]
                let cid = ids[Int(rng.next() % UInt64(ids.count))]
                let secs = Double(60 + Int(rng.next() % 900))
                let b = kinds[kind].behavior
                let f = secs / b.seconds
                let state: FocusStateCode = kind == focusKind || kind == 2 ? .onTrack : .offTrack
                let seg = try store.insertSegment(contextID: cid, start: t, clusterID: nil, confidence: 0.9, focusState: state)
                try store.extendSegment(id: seg, end: t.addingTimeInterval(secs), activeSeconds: secs, keys: b.keys * f, clicks: b.clicks * f,
                                        scrolls: b.scrolls * f, moves: b.moves * f, mediaSeconds: b.mediaSeconds * f, clusterID: nil,
                                        confidence: 0.9, focusState: state, throttle: state == .offTrack && secs > 300 ? 0.4 : 0)
                try store.addContextActivity(id: cid, seconds: secs, keys: b.keys * f, clicks: b.clicks * f, scrolls: b.scrolls * f,
                                             moves: b.moves * f, mediaSeconds: b.mediaSeconds * f, at: t)
                if state == .offTrack {
                    let ep = try store.insertEpisode(start: t, contextID: cid, clusterID: nil)
                    try store.updateEpisode(id: ep, end: t.addingTimeInterval(min(secs, 240)), maxLevel: secs > 300 ? 0.4 : 0,
                                            nudges: 1, outcome: .returned)
                }
                t = t.addingTimeInterval(secs + Double(rng.next() % 120))
                if hour == 12 && rng.uniform() < 0.3 { t = t.addingTimeInterval(45 * 60) } // lunch
            }
        }
        let defaults = UserDefaults(suiteName: "tf-demo-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let withLLM = CommandLine.arguments.contains("--with-llm")
        settings.update { $0.llmBackend = withLLM ? .automatic : .none; $0.minLearningDays = 3; $0.minLearningHours = 6 }
        let pipeline = try LearningPipeline(paths: paths, settings: settings, models: ModelManager(paths: paths))
        _ = await pipeline.run(trigger: .manual)
        // name clusters after the dominant demo kind, like a user would
        let clusters = try store.clusters()
        var used = Set<String>()
        for c in clusters {
            let members = try store.topContexts(cluster: c.id, limit: 20).map(\.id)
            var votes: [Int: Int] = [:]
            for m in members { if let k = ctxIDs.firstIndex(where: { $0.contains(m) }) { votes[k, default: 0] += 1 } }
            if let k = votes.max(by: { $0.value < $1.value })?.key, !used.contains(kinds[k].name) {
                used.insert(kinds[k].name)
                try store.renameCluster(id: c.id, name: kinds[k].name)
            }
        }
        pipeline.setPhase(.active)
        let named = try store.clusters()
        let work = named.first { $0.name == "עבודה" }?.id
        let study = named.first { $0.name == "לימודים" }?.id
        let comm = named.first { $0.name == "תקשורת ומיילים" }?.id
        var blocks: [FocusBlock] = []
        if let work { blocks.append(FocusBlock(startMinute: 9 * 60, endMinute: 13 * 60, clusterIDs: [work] + (comm.map { [$0] } ?? []), note: "פיצ'ר חדש")) }
        if let study { blocks.append(FocusBlock(startMinute: 14 * 60, endMinute: 17 * 60, clusterIDs: [study], note: "תרגיל בית 4")) }
        try store.savePlan(DayPlan(day: Date().dayKey, blocks: blocks))
        print("demo data at \(dir.path): \(named.count) activity types — " + named.map(\.displayName).joined(separator: ", "))
        print("student accuracy: \(pipeline.status.studentAccuracy ?? -1)")
    }
}
