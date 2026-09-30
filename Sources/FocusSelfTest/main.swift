import Darwin
import FocusCore
import FocusML
import Foundation

// FocusSelfTest — executable test-suite (XCTest is not available with Command Line Tools only).
// Usage: FocusSelfTest [filter]

ThrottleWatchdog.runIfRequested() // this binary doubles as the watchdog in the watchdog test

if let i = CommandLine.arguments.firstIndex(of: "--cluster-report"), CommandLine.arguments.count > i + 1 {
    do { try ClusterReport.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { print("report failed: \(error)") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--evidence-report"), CommandLine.arguments.count > i + 1 {
    do { try EvidenceReport.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1])) } catch { print("report failed: \(error)") }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--llm-check") {
    let model = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "gemma-3-1b-it-Q4_K_M"
    let sem = DispatchSemaphore(value: 0)
    Task.detached { await LLMCheck.run(modelID: model); sem.signal() }
    sem.wait()
    exit(0)
}

if CommandLine.arguments.contains("--apple-intelligence") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached { await LLMCheck.runAppleIntelligence(); sem.signal() }
    sem.wait()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--make-demo"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await DemoData.make(at: dir) } catch { print("demo failed: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

var failures = 0
var passed = 0
let filter = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }

func expect(_ cond: @autoclosure () throws -> Bool, _ msg: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
    let ok: Bool
    do { ok = try cond() } catch { failures += 1; print("    ✗ threw \(error): \(msg())  (\(file):\(line))"); return }
    if !ok {
        failures += 1
        print("    ✗ \(msg())  (\(file):\(line))")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    if let f = filter, !name.lowercased().contains(f.lowercased()) { return }
    let before = failures
    let t0 = Date()
    print("• \(name)")
    do { try body() } catch { failures += 1; print("    ✗ threw \(error)") }
    if failures == before { passed += 1 }
    print(String(format: "  %@ %.2fs", failures == before ? "ok" : "FAILED", Date().timeIntervalSince(t0)))
}

func asyncTest(_ name: String, _ body: @escaping () async throws -> Void) {
    test(name) {
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        Task.detached { do { try await body() } catch { err = error }; sem.signal() }
        sem.wait()
        if let err { throw err }
    }
}

func tempDir(_ name: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("tf-selftest-\(name)-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: - Math

test("gemm matches naive matmul (all transposes)") {
    var rng = SeededRandom(seed: 1)
    let m = 7, n = 5, k = 9
    for (ta, tb) in [(false, false), (true, false), (false, true), (true, true)] {
        let A = (0..<(m * k)).map { _ in rng.gaussian() }
        let B = (0..<(k * n)).map { _ in rng.gaussian() }
        let C = LA.matmul(A, B, m: m, n: n, k: k, transA: ta, transB: tb)
        for i in 0..<m { for j in 0..<n {
            var s: Float = 0
            for p in 0..<k {
                let a = ta ? A[p * m + i] : A[i * k + p]
                let b = tb ? B[j * k + p] : B[p * n + j]
                s += a * b
            }
            expect(abs(s - C[i * n + j]) < 1e-3, "C[\(i),\(j)] \(C[i * n + j]) vs \(s) ta=\(ta) tb=\(tb)")
        } }
    }
}

// MARK: - Text features

test("tokenizer handles Hebrew prefixes, acronyms and numbers") {
    let w = TextTokenizer.words("והמטריצה של צה\"ל: Lecture 12, 2026 ו-1234567")
    expect(w.contains("והמטריצה"), "hebrew word kept: \(w)")
    expect(w.contains("צהל"), "acronym joined: \(w)")
    expect(w.contains("2026") && w.contains("#num"), "numbers: \(w)")
    let v = TextTokenizer.hebrewVariants("והמטריצה")
    expect(v.contains("המטריצה") && v.contains("מטריצה"), "prefix variants: \(v)")
    expect(TextTokenizer.charNGrams("abc", sizes: [3]) == ["<ab", "abc", "bc>"], "char n-grams")
}

test("context normalizer strips counters and app suffixes, parses URLs") {
    expect(ContextNormalizer.cleanTitle("(3) WhatsApp", appName: "WhatsApp") == "WhatsApp", "leading counter")
    expect(ContextNormalizer.cleanTitle("Inbox (1,234) - me@x.com - Gmail - Google Chrome", appName: "Google Chrome") == "Inbox - me@x.com - Gmail",
           "gmail: \(ContextNormalizer.cleanTitle("Inbox (1,234) - me@x.com - Gmail - Google Chrome", appName: "Google Chrome"))")
    expect(ContextNormalizer.cleanTitle("Funny cats - YouTube - Audio playing", appName: "Google Chrome") == "Funny cats - YouTube", "audio suffix")
    let p = ContextNormalizer.parseURL("www.moodle.tau.ac.il/course/view.php?id=5")
    expect(p.host == "moodle.tau.ac.il" && p.path == "/course/view.php", "url \(p)")
    let k1 = ContextNormalizer.key(bundleID: "a", host: "h", path: "/x/y", cleanTitle: "T")
    let k2 = ContextNormalizer.key(bundleID: "a", host: "h", path: "/x/z", cleanTitle: "t")
    expect(k1 == k2, "key uses path head + case-insensitive title")
    expect(ContextNormalizer.redact("card 4580 1234 5678 9012 mail a.b@c.com") == "card ••• mail •••", ContextNormalizer.redact("card 4580 1234 5678 9012 mail a.b@c.com"))
}

// MARK: - Student network on synthetic activity data

struct SyntheticType {
    let name: String
    let apps: [(String, String)]
    let hosts: [String]
    let vocab: [String]
    let behavior: BehaviorStats
}

let syntheticTypes: [SyntheticType] = [
    SyntheticType(name: "dev", apps: [("com.microsoft.VSCode", "Code"), ("com.apple.Terminal", "Terminal"), ("com.google.Chrome", "Google Chrome")],
                  hosts: ["github.com", "stackoverflow.com", "developer.apple.com"],
                  vocab: ["swift", "func", "struct", "build", "error", "compile", "pull", "request", "merge", "branch", "api", "test", "deploy", "refactor", "bug", "commit"],
                  behavior: BehaviorStats(seconds: 600, keys: 900, clicks: 60, scrolls: 80, moves: 3000)),
    SyntheticType(name: "study", apps: [("com.google.Chrome", "Google Chrome"), ("com.apple.Preview", "Preview")],
                  hosts: ["moodle.tau.ac.il", "coursera.org"],
                  vocab: ["אלגברה", "לינארית", "הרצאה", "תרגיל", "מטריצה", "וקטור", "משפט", "הוכחה", "eigenvalue", "matrix", "lecture", "homework", "קורס", "יחידה"],
                  behavior: BehaviorStats(seconds: 600, keys: 150, clicks: 40, scrolls: 400, moves: 2500)),
    SyntheticType(name: "video", apps: [("com.google.Chrome", "Google Chrome"), ("com.apple.TV", "TV")],
                  hosts: ["youtube.com", "netflix.com"],
                  vocab: ["funny", "compilation", "trailer", "episode", "season", "vlog", "reaction", "music", "live", "highlights", "cats", "prank"],
                  behavior: BehaviorStats(seconds: 600, keys: 5, clicks: 6, scrolls: 20, moves: 300, mediaSeconds: 550)),
    SyntheticType(name: "social", apps: [("com.google.Chrome", "Google Chrome"), ("net.whatsapp.WhatsApp", "WhatsApp")],
                  hosts: ["facebook.com", "instagram.com", "x.com"],
                  vocab: ["feed", "post", "likes", "story", "friends", "reels", "comments", "share", "notifications", "הודעה", "קבוצה", "חברים"],
                  behavior: BehaviorStats(seconds: 600, keys: 120, clicks: 90, scrolls: 700, moves: 2000)),
    SyntheticType(name: "mail", apps: [("com.apple.mail", "Mail"), ("com.google.Chrome", "Google Chrome")],
                  hosts: ["mail.google.com", "outlook.office.com"],
                  vocab: ["inbox", "reply", "invoice", "meeting", "schedule", "draft", "attachment", "forward", "חשבונית", "פגישה", "תשלום", "הזמנה"],
                  behavior: BehaviorStats(seconds: 600, keys: 400, clicks: 120, scrolls: 150, moves: 2500)),
]

func synthDescriptor(_ t: SyntheticType, _ rng: inout SeededRandom, novelWords: [String] = []) -> ActivityDescriptor {
    let app = t.apps[Int(rng.next() % UInt64(t.apps.count))]
    let isBrowser = app.0 == "com.google.Chrome"
    let host = isBrowser ? t.hosts[Int(rng.next() % UInt64(t.hosts.count))] : nil
    var titleWords: [String] = []
    for _ in 0..<(3 + Int(rng.next() % 4)) { titleWords.append(t.vocab[Int(rng.next() % UInt64(t.vocab.count))]) }
    titleWords += novelWords
    var textWords: [String] = []
    for _ in 0..<25 { textWords.append(t.vocab[Int(rng.next() % UInt64(t.vocab.count))]) }
    var b = t.behavior
    let jitter = Double(0.6 + rng.uniform() * 0.8)
    b.keys *= jitter; b.scrolls *= jitter; b.clicks *= jitter
    return ActivityDescriptor(bundleID: app.0, appName: app.1, title: titleWords.joined(separator: " "), host: host,
                              urlPath: host.map { _ in "/" + (titleWords.first ?? "x") }, text: textWords.joined(separator: " "),
                              behavior: b, hourOfDay: Double(8 + rng.next() % 12))
}

test("student network learns activity types and generalises to unseen titles") {
    var rng = SeededRandom(seed: 5)
    let featurizer = ActivityFeaturizer()
    let D = 32
    let anchors = syntheticTypes.map { _ in LA.normalized((0..<D).map { _ in rng.gaussian() }) }
    var samples: [StudentSample] = []
    for (ci, t) in syntheticTypes.enumerated() {
        for _ in 0..<80 {
            let d = synthDescriptor(t, &rng)
            var teacher = anchors[ci]
            for k in 0..<D { teacher[k] += 0.3 * rng.gaussian() / Float(D).squareRoot() }
            samples.append(StudentSample(x: featurizer.featurize(d), label: ci, weight: 1, teacher: LA.normalized(teacher)))
        }
    }
    var cfg = StudentConfig()
    cfg.semanticDim = D
    cfg.classCount = syntheticTypes.count
    cfg.buckets = 1 << 14
    let net = StudentNetwork(config: cfg, classIDs: syntheticTypes.indices.map { Int64($0 + 1) })
    var o = StudentTrainingOptions()
    o.epochs = 25
    let r = net.train(samples, options: o)
    print("    train loss \(r.trainLoss), val acc \(r.validationAccuracy ?? -1), val cos \(r.validationSemanticCosine ?? -1), \(String(format: "%.2f", r.seconds))s")
    expect((r.validationAccuracy ?? 0) > 0.9, "validation accuracy \(r.validationAccuracy ?? -1)")
    expect((r.validationSemanticCosine ?? 0) > 0.8, "semantic cosine \(r.validationSemanticCosine ?? -1)")
    // generalisation: unseen words mixed into titles, text removed (concept drift: new content, same kind of activity)
    var correct = 0
    for (ci, t) in syntheticTypes.enumerated() {
        for j in 0..<20 {
            var d = synthDescriptor(t, &rng, novelWords: ["brandnew\(j)", "topic\(j * 7)"])
            d.text = nil
            let p = net.predict(featurizer.featurize(d)).probabilities
            if p.indices.max(by: { p[$0] < p[$1] }) == ci { correct += 1 }
        }
    }
    let acc = Double(correct) / Double(20 * syntheticTypes.count)
    print("    drift accuracy (novel words, no text): \(acc)")
    expect(acc > 0.85, "drift accuracy \(acc)")
    // real-time cost: featurize + forward pass
    let probe = synthDescriptor(syntheticTypes[0], &rng)
    let t0 = Date()
    for _ in 0..<1000 { _ = net.predict(featurizer.featurize(probe)) }
    let perCall = Date().timeIntervalSince(t0) / 1000 * 1000
    print(String(format: "    real-time inference: %.3f ms per window (featurize + forward)", perCall))
    expect(perCall < 1.0, "inference should take < 1 ms")
    // serialisation round-trip
    let copy = try StudentNetwork(serialized: net.serialized())
    let x = featurizer.featurize(synthDescriptor(syntheticTypes[2], &rng))
    let a = net.predict(x).probabilities, b = copy.predict(x).probabilities
    expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "serialisation changes predictions")
}

// MARK: - Clustering

test("NN-chain average linkage equals naive UPGMA") {
    var rng = SeededRandom(seed: 9)
    let n = 40
    let pts = (0..<n).map { _ in LA.normalized((0..<8).map { _ in rng.gaussian() }) }
    let w = (0..<n).map { _ in 0.5 + rng.uniform() }
    var D = [Float](repeating: 0, count: n * n)
    for i in 0..<n { for j in 0..<n { D[i * n + j] = 1 - LA.dot(pts[i], pts[j]) } }
    var D2 = D
    let merges = Agglomerative.linkage(distances: &D2, n: n, weights: w)
    // naive
    var clusters: [[Int]] = (0..<n).map { [$0] }
    var naive: [Float] = []
    while clusters.count > 1 {
        var best = (Float.infinity, 0, 0)
        for a in 0..<clusters.count { for b in (a + 1)..<clusters.count {
            var s: Float = 0, ws: Float = 0
            for i in clusters[a] { for j in clusters[b] { s += w[i] * w[j] * D[i * n + j]; ws += w[i] * w[j] } }
            if s / ws < best.0 { best = (s / ws, a, b) }
        } }
        naive.append(best.0)
        clusters[best.1] += clusters[best.2]
        clusters.remove(at: best.2)
    }
    let got = merges.map(\.distance)
    expect(got.count == naive.count, "merge count")
    expect(zip(got, naive.sorted()).allSatisfy { abs($0 - $1) < 1e-4 }, "merge heights differ: \(Array(got.prefix(5))) vs \(Array(naive.sorted().prefix(5)))")
}

test("auto-cluster recovers planted activity groups") {
    var rng = SeededRandom(seed: 3)
    let centers = (0..<6).map { _ in LA.normalized((0..<48).map { _ in rng.gaussian() }) }
    var pts: [[Float]] = [], truth: [Int] = [], w: [Float] = []
    for (ci, c) in centers.enumerated() {
        for _ in 0..<(30 + ci * 5) {
            var v = c
            for k in 0..<48 { v[k] += 0.12 * rng.gaussian() }
            pts.append(LA.normalized(v)); truth.append(ci); w.append(0.5 + rng.uniform())
        }
    }
    let r = AutoCluster.run(vectors: pts, weights: w, kRange: 3...12)
    var purity = 0
    for l in 0..<r.k {
        let members = r.labels.indices.filter { r.labels[$0] == l }
        var counts: [Int: Int] = [:]
        for m in members { counts[truth[m], default: 0] += 1 }
        purity += counts.values.max() ?? 0
    }
    let pur = Double(purity) / Double(pts.count)
    print("    k=\(r.k) silhouette=\(r.silhouette) purity=\(pur)")
    expect(r.k == 6, "expected 6 clusters, got \(r.k)")
    expect(pur > 0.97, "purity \(pur)")
}

test("prototype index flags novel vectors") {
    var rng = SeededRandom(seed: 4)
    let c0 = LA.normalized((0..<32).map { _ in rng.gaussian() }), c1 = LA.normalized((0..<32).map { _ in rng.gaussian() })
    var vecs: [[Float]] = [], labels: [Int] = []
    for (i, c) in [c0, c1].enumerated() {
        for _ in 0..<30 { var v = c; for k in 0..<32 { v[k] += 0.1 * rng.gaussian() }; vecs.append(LA.normalized(v)); labels.append(i) }
    }
    let idx = PrototypeIndex.build(vectors: vecs, weights: vecs.map { _ in 1 }, labels: labels, classIDs: [10, 20])
    var probe = c1; for k in 0..<32 { probe[k] += 0.1 * rng.gaussian() }
    let m = idx.bestMatch(LA.normalized(probe))!
    expect(m.classIndex == 1 && !m.isNovel, "known probe \(m)")
    let novel = LA.normalized((0..<32).map { _ in rng.gaussian() })
    expect(idx.bestMatch(novel)!.isNovel, "random vector should be novel")
}

test("temporal smoother is sticky within a context and fast across switches") {
    var s = TemporalSmoother()
    _ = s.update(likelihood: [0.9, 0.1], contextChanged: true)
    let noisy = s.update(likelihood: [0.3, 0.7], contextChanged: false)
    expect(noisy[0] > 0.5, "single noisy tick should not flip: \(noisy)")
    let switched = s.update(likelihood: [0.05, 0.95], contextChanged: true)
    expect(switched[1] > 0.5, "confident switch should flip: \(switched)")
}

test("c-TF-IDF keywords are cluster-specific") {
    let scores = KeywordExtractor.scores([
        ["swift": 2, "xcode": 1, "build": 1, "the": 1, "compile": 1],
        ["youtube": 1, "cats": 2, "the": 1, "funny": 1],
    ])
    let top = scores.map { s in s.sorted { $0.value > $1.value }.prefix(2).map(\.key) }
    expect(top[0].contains("swift") && top[1].contains("cats"), "\(top)")
    expect(scores[0]["the"]! < scores[0]["xcode"]!, "a word shared by both clusters ranks below a distinctive one")
}

/// Two conversations in a chat app whose title never changes ("Claude"): one for a course, one for work.
func evidenceFixture() -> [EvidenceRow] {
    let chatChrome = "Claude is responding\nThinking some more…\n856 tokens\nSessions\nPull requests\n1m 16s"
    func b(_ s: Double, keys: Double = 0) -> BehaviorStats { BehaviorStats(seconds: s, keys: keys, scrolls: s / 10) }
    return [
        EvidenceRow(id: 1, bundleID: "com.google.Chrome", appName: "Google Chrome",
                    title: "אלגברה לינארית 1 - הרצאה 3: מרחבים וקטוריים", host: "moodle.tau.ac.il", urlPath: "/course/view.php",
                    text: "הגדרה: מרחב וקטורי מעל שדה\nבאלגברה לינארית כל מרחב וקטורי הוא קבוצה\nSearch\nMenu",
                    behavior: b(900), activity: "studying linear algebra", category: "studying / coursework", topic: "linear algebra",
                    clusterID: 1),
        EvidenceRow(id: 2, bundleID: "com.anthropic.claudefordesktop", appName: "Claude", title: "Claude",
                    text: chatChrome + "\nעזרה בתרגיל באלגברה לינארית: ערכים עצמיים של מטריצה\nאיך מוצאים ערכים עצמיים של מטריצה סימטרית\nעכשיו ואני רוצה לבדוק שוב",
                    behavior: b(1200, keys: 900), activity: "asking an AI about homework", category: "studying / coursework",
                    topic: "eigenvalues", clusterID: 1, assignment: .prototype, confidence: 0.7),
        EvidenceRow(id: 3, bundleID: "com.anthropic.claudefordesktop", appName: "Claude", title: "Claude",
                    text: chatChrome + "\nDeploy the backend API to staging and fix the failing migration\nThe backend migration fails on staging because an index is missing",
                    behavior: b(1000, keys: 1500), activity: "debugging a backend deployment", category: "software development",
                    topic: "backend migration", clusterID: 2, assignment: .llm, confidence: 0.8),
        EvidenceRow(id: 4, bundleID: "com.microsoft.VSCode", appName: "Code", title: "migration.py — backend-service",
                    text: "def upgrade(): op.create_index('orders_user_id')\nrevision identifiers used by Alembic",
                    behavior: b(800, keys: 2000), activity: "writing a database migration", category: "software development",
                    topic: "database migration", clusterID: 2),
    ]
}

test("activity evidence: keywords from screen text, titles and addresses — not the app's interface") {
    let snap = ActivityEvidence.build(evidenceFixture())
    guard let study = snap.clusters[1], let work = snap.clusters[2] else { expect(false, "both types present"); return }
    let studyText = study.textTerms.map(\.term), workText = work.textTerms.map(\.term)
    let address = study.addressTerms.map(\.term)
    expect(address.contains("moodle.tau.ac.il"), "the website is evidence: \(address)")
    expect(address.contains("אלגברה לינארית"), "words that stand together in a title become one phrase: \(address)")
    expect(studyText.contains { $0.contains("ערכים עצמיים") } && studyText.contains("מטריצה"),
           "what the chat was about comes from its text: \(studyText)")
    let workAll = workText + work.addressTerms.map(\.term)
    expect(workText.contains { $0.contains("staging") } && workAll.contains { $0.lowercased().contains("backend") },
           "work chat: \(workText) / \(work.addressTerms.map(\.term))")
    expect(Set(workText.map { $0.lowercased() }).isDisjoint(with: work.addressTerms.map { $0.term.lowercased() }),
           "a word is shown once per type")
    let all = (study.textTerms + work.textTerms + study.addressTerms + work.addressTerms).map { $0.term.lowercased() }
    for noise in ["tokens", "thinking", "responding", "sessions", "pull", "requests", "claude", "search", "menu", "ואני", "עכשיו", "1m"] {
        expect(!all.contains { $0.split(separator: " ").contains(Substring(noise)) }, "interface/function word shown: \(noise)")
    }
    expect(!all.contains("באלגברה"), "a Hebrew prefix is folded into the base word")
    let chat = study.windows.first { $0.id == 2 }!
    expect(!chat.hasInformativeTitle && study.windows.first { $0.id == 1 }!.hasInformativeTitle, "title informativeness")
    expect(chat.terms.contains { $0.term.contains("ערכים") } && chat.terms.allSatisfy { $0.sources.contains(.text) },
           "a chat window is described by its own text: \(chat.terms.map(\.term))")
    expect(chat.textLines.first == "Claude is responding" && chat.assignment == .prototype, "window details")
    expect(study.descriptions.first?.activity == "asking an AI about homework", "descriptions by time: \(study.descriptions)")
    expect(study.categories.first?.category == "studying / coursework" && abs(study.categories[0].share - 1) < 1e-9, "categories")
    expect(abs(work.behavior.seconds - 1800) < 1e-9 && work.behavior.keys == 3500, "behaviour is summed")
    expect(study.keywords.count >= 4 && work.keywords.contains { $0.lowercased() == "migration" }, "keywords: \(work.keywords)")
    expect(snap.unassigned == nil, "no unassigned group")
    expect(ActivityEvidence.build(evidenceFixture()) == snap, "deterministic")
}

test("activity evidence: words an app shows in all its windows are not evidence for a type") {
    let chrome = "Threads Huddles Canvases\nDirect messages"
    let rows = [
        EvidenceRow(id: 1, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#dev-team - Acme",
                    text: chrome + "\ndeploy to staging finished, code review at noon", behavior: BehaviorStats(seconds: 600), clusterID: 1),
        EvidenceRow(id: 2, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#family",
                    text: chrome + "\nמה שלומכם? נפגשים בערב לארוחה", behavior: BehaviorStats(seconds: 500), clusterID: 2),
        EvidenceRow(id: 3, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#dev-alerts - Acme",
                    text: chrome + "\nstaging deploy failed: migration timeout", behavior: BehaviorStats(seconds: 300), clusterID: 1),
    ]
    let snap = ActivityEvidence.build(rows)
    let text = (snap.clusters[1]!.textTerms + snap.clusters[2]!.textTerms).map { $0.term.lowercased() }
    expect(!text.contains { ["threads", "huddles", "canvases", "direct", "messages"].contains($0) }, "app chrome: \(text)")
    expect(text.contains("staging") && text.contains("deploy") && text.contains("לארוחה"),
           "content shared by windows of one type stays: \(text)")
    expect(!ActivityEvidence.isInformativeTitle("Open", appName: "Preview", host: nil)
           && !ActivityEvidence.isInformativeTitle("claude", appName: "Claude", host: nil)
           && ActivityEvidence.isInformativeTitle("#family", appName: "Slack", host: nil), "informative titles")
}

// MARK: - Focus controller

test("focus controller escalates drift, releases on return, never punishes the unknown") {
    var settings = AppSettings()
    settings.strictness = .normal
    let fc = FocusController(settings: settings)
    let t0 = Date()
    let focus = ActiveFocus(clusterIDs: [1], start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(3600), isManual: true)
    func input(_ t: Double, _ dist: [ClusterID: Double], novelty: Double = 0, source: Classification.Source = .assigned, ctx: ContextID = 7) -> FocusInput {
        FocusInput(now: t0.addingTimeInterval(t), focus: focus,
                   classification: Classification(clusterID: dist.max { $0.value < $1.value }?.key, confidence: dist.values.max() ?? 0,
                                                  novelty: novelty, distribution: dist, source: source),
                   contextID: ctx, isPrivate: false, isOwnApp: false, contextAllowed: false, contextDenied: false, alwaysAllowed: [])
    }
    expect(fc.evaluate(input(0, [1: 0.9, 2: 0.1])).verdict == .onTrack, "on track")
    var nudgeAt: Double?, throttleAt: Double?
    var lastLevel = 0.0
    var monotonic = true
    for t in stride(from: 10.0, through: 400, by: 5) {
        let o = fc.evaluate(input(t, [1: 0.05, 2: 0.95]))
        expect(o.verdict == .offTrack, "off track at \(t)")
        if o.nudge && nudgeAt == nil { nudgeAt = t - 10 }
        if o.throttleLevel > 0 && throttleAt == nil { throttleAt = t - 10 }
        if o.throttleLevel + 1e-9 < lastLevel { monotonic = false }
        lastLevel = o.throttleLevel
    }
    print("    nudge after \(nudgeAt ?? -1)s, slowdown after \(throttleAt ?? -1)s, final level \(lastLevel)")
    expect(nudgeAt != nil && nudgeAt! <= 20, "nudge timing")
    expect(throttleAt != nil && throttleAt! >= 40 && throttleAt! <= 50, "throttle timing \(throttleAt ?? -1)")
    expect(monotonic && lastLevel > 0.8 && lastLevel <= settings.maxThrottle + 1e-9, "ramp \(lastLevel)")
    let back = fc.evaluate(input(405, [1: 0.95, 2: 0.05]))
    expect(back.verdict == .onTrack && back.throttleLevel == 0 && back.episodeEnded == .returned, "release on return \(back)")
    // unknown activity: no punishment, question after 45 s
    var asked = false
    for t in stride(from: 410.0, through: 470, by: 5) {
        let o = fc.evaluate(input(t, [1: 0.4, 2: 0.6], novelty: 0.9, source: .model, ctx: 99))
        expect(o.verdict == .uncertain && o.throttleLevel == 0, "uncertain must not throttle")
        asked = asked || o.ask
    }
    expect(asked, "should ask about an unfamiliar activity")
    // breaks
    expect(fc.startBreak(now: t0.addingTimeInterval(500)), "break allowed")
    expect(fc.evaluate(input(510, [2: 1])).verdict == .neutral, "break is neutral")
}

// MARK: - Storage

test("store: contexts, assignments (user wins), clusters, plans, merge") {
    let dir = tempDir("store")
    let store = try Store(url: dir.appendingPathComponent("t.sqlite"))
    let c = try store.insertContext(key: "k1", bundleID: "com.x", appName: "X", title: "Hello", host: "a.com", urlPath: "/p",
                                    docPath: nil, isPrivate: false, now: Date())
    try store.addContextActivity(id: c.id, seconds: 30, keys: 10, clicks: 2, scrolls: 3, moves: 40, mediaSeconds: 0, at: Date())
    try store.mergeContextText(id: c.id, text: "line one\nline two", now: Date())
    try store.mergeContextText(id: c.id, text: "line two\nline three", now: Date())
    let lc = try store.learningContexts(ids: [c.id]).first!
    expect(lc.text == "line two\nline three\nline one", "merged text: \(lc.text ?? "nil")")
    expect(lc.totalSeconds == 30 && lc.behavior.keys == 10, "stats")
    let a = try store.insertCluster(ActivityCluster(id: 0, autoName: "A"), now: Date())
    let b = try store.insertCluster(ActivityCluster(id: 0, autoName: "B"), now: Date())
    try store.setAssignments([(c.id, a, .user, 1)], now: Date())
    try store.setAssignments([(c.id, b, .autoCluster, 0.5)], now: Date())
    expect(try store.context(id: c.id)?.clusterID == a, "user assignment must survive automatic updates")
    try store.renameCluster(id: a, name: "עבודה")
    expect(try store.clusters().first { $0.id == a }?.displayName == "עבודה", "rename")
    try store.mergeCluster(a, into: b)
    expect(try store.context(id: c.id)?.clusterID == b, "merge moves contexts")
    expect(try store.clusters().allSatisfy { $0.id != a }, "merged cluster archived")
    let plan = DayPlan(day: "2026-09-25", blocks: [FocusBlock(startMinute: 540, endMinute: 720, clusterIDs: [b], note: "בוקר")])
    try store.savePlan(plan)
    expect(try store.plan(day: "2026-09-25") == plan, "plan round-trip")
    let seg = try store.insertSegment(contextID: c.id, start: Date(), clusterID: b, confidence: 0.9, focusState: .onTrack)
    try store.extendSegment(id: seg, end: Date().addingTimeInterval(5), activeSeconds: 5, keys: 1, clicks: 0, scrolls: 0, moves: 0,
                            mediaSeconds: 0, clusterID: b, confidence: 0.9, focusState: .onTrack, throttle: 0)
    expect(try store.clusterSeconds(from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60))[b] == 5, "cluster seconds")
    try? FileManager.default.removeItem(at: dir)
}

test("store: evidence rows are the heaviest windows of each type, without private or own windows") {
    let dir = tempDir("evidence")
    let store = try Store(url: dir.appendingPathComponent("t.sqlite"))
    var n = 0
    func add(_ secs: Double, cluster: ClusterID?, bundle: String = "com.x", isPrivate: Bool = false) throws -> ContextID {
        n += 1
        let c = try store.insertContext(key: "k\(n)", bundleID: bundle, appName: "X", title: "t\(n)", host: nil, urlPath: nil,
                                        docPath: nil, isPrivate: isPrivate, now: Date())
        try store.addContextActivity(id: c.id, seconds: secs, keys: 1, clicks: 0, scrolls: 0, moves: 0, mediaSeconds: 0, at: Date())
        if let cluster { try store.setAssignments([(c.id, cluster, .autoCluster, 0.5)], now: Date()) }
        return c.id
    }
    let a1 = try add(100, cluster: 7), a2 = try add(50, cluster: 7)
    _ = try add(30, cluster: 7)                                     // third heaviest: over the per-type limit
    _ = try add(500, cluster: 7, isPrivate: true)                   // private windows are never shown
    _ = try add(400, cluster: nil, bundle: AppPaths.ownBundleID)    // TimeFocus itself
    let u1 = try add(70, cluster: nil), u2 = try add(20, cluster: nil)
    _ = try add(5, cluster: nil)                                    // too short
    try store.mergeContextText(id: a1, text: "hello", now: Date())
    let rows = try store.evidenceRows(minSeconds: 10, perGroup: 2, excludingBundleIDs: [AppPaths.ownBundleID])
    expect(rows.map(\.id) == [a1, u1, a2, u2], "heaviest first, two per type: \(rows.map(\.id))")
    expect(rows.map(\.groupWindows) == [3, 2, 3, 2], "every row knows its type's full size: \(rows.map(\.groupWindows))")
    expect(ActivityEvidence.build(rows).clusters[7]?.totalWindows == 3, "total windows of a type")
    let first = rows.first!
    expect(first.clusterID == 7 && first.text == "hello" && first.seconds == 100 && first.assignment == .autoCluster
           && (first.hourSin != 0 || first.hourCos != 0), "row fields")
    try? FileManager.default.removeItem(at: dir)
}

test("LLM JSON extraction tolerates fences and chatter") {
    let s = "Sure! ```json\n{\"activity\": \"studying \\\"linear\\\" algebra\", \"category\": \"studying / coursework\", \"topic\": \"eigen {values}\"}\n``` hope it helps"
    let o = LLMTasks.extractJSON(s)
    expect(o?["activity"] as? String == "studying \"linear\" algebra", "\(String(describing: o))")
    expect(o?["topic"] as? String == "eigen {values}", "braces inside strings")
}

test("Apple Intelligence probe reads this build's FoundationModels imports") {
    let imported = AppleIntelligenceLLM.importedSymbols ?? []
    expect(!imported.isEmpty, "import table not readable")
    expect(imported.allSatisfy { $0.hasPrefix("$s16FoundationModels") }, "only FoundationModels symbols: \(imported.prefix(3))")
    expect(imported.contains { $0.contains("19SystemLanguageModel") }, "availability() calls SystemLanguageModel")
    let (available, reason) = AppleIntelligenceLLM.availability()
    expect(!available || AppleIntelligenceLLM.missingSymbols == [], "never available with missing symbols")
    print("    \(imported.count) imported, \(AppleIntelligenceLLM.missingSymbols?.count ?? -1) missing — \(reason)")
}

// MARK: - Throttling (real processes)

func processCPUTime(_ pid: pid_t) -> Double {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb) // task times are in Mach absolute-time units (not ns on Apple Silicon)
    return Double(info.pti_total_user + info.pti_total_system) * Double(tb.numer) / Double(tb.denom) / 1e9
}

func isStopped(_ pid: pid_t) -> Bool {
    var bsd = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
    return bsd.pbi_status == UInt32(SSTOP)
}

func spawnBusyLoop() throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "while :; do :; done"]
    try p.run()
    return p
}

test("throttler slows a real process proportionally and fully releases it") {
    let busy = try spawnBusyLoop()
    defer { busy.terminate() }
    let dir = tempDir("throttle")
    let th = ProcessThrottler(stateFile: dir.appendingPathComponent("state.json"))
    usleep(300_000)
    func cpuOver(_ secs: Double) -> Double {
        let a = processCPUTime(busy.processIdentifier)
        usleep(useconds_t(secs * 1_000_000))
        return (processCPUTime(busy.processIdentifier) - a) / secs
    }
    let base = cpuOver(1.0)
    th.set(target: busy.processIdentifier, bundleID: "test.busy", level: 0.8)
    usleep(300_000)
    let slowed = cpuOver(2.0)
    th.releaseAll()
    usleep(400_000)
    let after = cpuOver(1.0)
    print(String(format: "    cpu share: base %.2f → throttled(0.8) %.2f → released %.2f", base, slowed, after))
    expect(slowed < base * 0.45, "throttled CPU should drop well below base")
    expect(after > base * 0.8, "CPU should recover after release")
    expect(!isStopped(busy.processIdentifier), "process must not be left stopped")
    th.shutdown()
    try? FileManager.default.removeItem(at: dir)
}

test("watchdog (separate tf-watchdog process) resumes only what the app paused, after kill -9") {
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tf-watchdog")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { expect(false, "tf-watchdog not built"); return }
    let ours = try spawnBusyLoop()        // paused by "the app" and recorded in the state file
    let foreign = try spawnBusyLoop()     // stopped by the user (Ctrl-Z) — must stay stopped
    let recycled = try spawnBusyLoop()    // recorded with a wrong start time (pid reuse) — must not be touched
    defer { ours.terminate(); foreign.terminate(); recycled.terminate() }
    let dir = tempDir("watchdog")
    let state = dir.appendingPathComponent("state.json")
    let start = ProcessTree.bsd(ours.processIdentifier)!.start
    try JSONSerialization.data(withJSONObject: ["procs": [
        ["pid": Int(ours.processIdentifier), "start": NSNumber(value: start)],
        ["pid": Int(recycled.processIdentifier), "start": NSNumber(value: 12345)],
    ], "updated": 0]).write(to: state)
    for p in [ours, foreign, recycled] { kill(p.processIdentifier, SIGSTOP) }
    usleep(100_000)
    // stand-in for the app: a process we SIGKILL, exactly like `killall -9 TimeFocus` (which cannot match "tf-watchdog")
    let fakeApp = Process()
    fakeApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
    fakeApp.arguments = ["30"]
    try fakeApp.run()
    let wd = Process()
    wd.executableURL = helper
    wd.arguments = [String(fakeApp.processIdentifier), state.path]
    try wd.run()
    usleep(200_000)
    kill(fakeApp.processIdentifier, SIGKILL)
    wd.waitUntilExit()
    usleep(200_000)
    expect(!isStopped(ours.processIdentifier), "the process the app paused must be resumed")
    expect(isStopped(foreign.processIdentifier), "a process stopped by someone else must stay stopped")
    expect(isStopped(recycled.processIdentifier), "a recycled pid (start time mismatch) must not be touched")
    for p in [foreign, recycled] { kill(p.processIdentifier, SIGCONT) }
    try? FileManager.default.removeItem(at: dir)
}

test("throttler never takes over a process that somebody else stopped") {
    let busy = try spawnBusyLoop()
    defer { busy.terminate() }
    kill(busy.processIdentifier, SIGSTOP) // e.g. a suspended job inside the target app
    usleep(100_000)
    let dir = tempDir("throttle-foreign")
    let th = ProcessThrottler(stateFile: dir.appendingPathComponent("state.json"))
    th.set(target: busy.processIdentifier, bundleID: "test", level: 0.7)
    usleep(1_200_000)
    th.releaseAll()
    usleep(300_000)
    expect(isStopped(busy.processIdentifier), "must still be stopped after throttling and release")
    th.shutdown()
    expect(isStopped(busy.processIdentifier), "shutdown must not resume it either")
    kill(busy.processIdentifier, SIGCONT)
    try? FileManager.default.removeItem(at: dir)
}

test("focus controller: time away never counts as drift (no jump to maximum slowdown on return)") {
    var settings = AppSettings()
    settings.strictness = .strict
    let fc = FocusController(settings: settings)
    let t0 = Date()
    let focus = ActiveFocus(clusterIDs: [1], start: t0.addingTimeInterval(-60), end: t0.addingTimeInterval(7200), isManual: true)
    let off = Classification(clusterID: 2, confidence: 0.95, novelty: 0, distribution: [1: 0.05, 2: 0.95], source: .assigned)
    func input(_ t: Double) -> FocusInput {
        FocusInput(now: t0.addingTimeInterval(t), focus: focus, classification: off, contextID: 3, isPrivate: false, isOwnApp: false,
                   contextAllowed: false, contextDenied: false, alwaysAllowed: [])
    }
    _ = fc.evaluate(input(0)); _ = fc.evaluate(input(4)); _ = fc.evaluate(input(8))
    fc.noteAway()                               // screen locked for 10 minutes
    let back = fc.evaluate(input(608))
    print(String(format: "    after 8 s of drift + 10 min away: drift %.0f s, level %.2f", back.driftSeconds, back.throttleLevel))
    expect(back.driftSeconds < 20 && back.throttleLevel < 0.2, "away time must not be counted")
    // episode summary survives the reset that ends the episode
    var summary: EpisodeSummary?
    for t in stride(from: 612.0, through: 700, by: 4) { _ = fc.evaluate(input(t)) }
    let onTrack = Classification(clusterID: 1, confidence: 0.95, novelty: 0, distribution: [1: 0.95, 2: 0.05], source: .assigned)
    let end = fc.evaluate(FocusInput(now: t0.addingTimeInterval(704), focus: focus, classification: onTrack, contextID: 4, isPrivate: false,
                                      isOwnApp: false, contextAllowed: false, contextDenied: false, alwaysAllowed: []))
    summary = end.endedEpisode
    expect(end.episodeEnded == .returned && (summary?.nudges ?? 0) >= 1 && (summary?.maxLevel ?? 0) > 0,
           "ended episode keeps its nudges and max level: \(String(describing: summary))")
}

test("cluster ids are never reused, even after deleting all data") {
    let dir = tempDir("ids")
    let store = try Store(url: dir.appendingPathComponent("t.sqlite"))
    let a = try store.insertCluster(ActivityCluster(id: 0, autoName: "A"), now: Date())
    let b = try store.insertCluster(ActivityCluster(id: 0, autoName: "B"), now: Date())
    try store.deleteAllData()
    let c = try store.insertCluster(ActivityCluster(id: 0, autoName: "C"), now: Date())
    expect(c > max(a, b), "new id \(c) must be greater than old ids \(a), \(b)")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - End-to-end learning on synthetic data

asyncTest("learning pipeline end-to-end: clusters, student, drift to unseen content") {
    let dir = tempDir("pipeline")
    let paths = AppPaths(support: dir)
    let realModels = AppPaths.default.models
    try? FileManager.default.removeItem(at: paths.models)
    try FileManager.default.createSymbolicLink(at: paths.models, withDestinationURL: realModels)
    let defaults = UserDefaults(suiteName: "tf-selftest-\(UUID().uuidString)")!
    let settings = SettingsStore(defaults: defaults)
    settings.update { $0.llmBackend = .none; $0.minLearningDays = 0; $0.minLearningHours = 0 }
    let store = try Store(url: paths.database)
    var rng = SeededRandom(seed: 21)
    var truthByContext: [ContextID: Int] = [:]
    for (ci, t) in syntheticTypes.enumerated() {
        for j in 0..<35 {
            let d = synthDescriptor(t, &rng)
            let c = try store.insertContext(key: "\(t.name)-\(j)", bundleID: d.bundleID, appName: d.appName, title: d.title,
                                            host: d.host, urlPath: d.urlPath, docPath: nil, isPrivate: false, now: Date())
            let secs = 60 + Double(rng.next() % 1800)
            let f = secs / d.behavior.seconds
            try store.addContextActivity(id: c.id, seconds: secs, keys: d.behavior.keys * f, clicks: d.behavior.clicks * f,
                                         scrolls: d.behavior.scrolls * f, moves: d.behavior.moves * f,
                                         mediaSeconds: d.behavior.mediaSeconds * f, at: Date())
            try store.mergeContextText(id: c.id, text: d.text ?? "", now: Date())
            truthByContext[c.id] = ci
        }
    }
    let manager = ModelManager(paths: paths)
    let pipeline = try LearningPipeline(paths: paths, settings: settings, models: manager)
    var bundle: ModelBundle?
    pipeline.onBundle = { bundle = $0 }
    let ok = await pipeline.run(trigger: .manual)
    let st = pipeline.status
    print("    embedding model: \(st.embeddingModel), stage \(st.stage), acc \(st.studentAccuracy ?? -1), cos \(st.studentSemanticCosine ?? -1)")
    expect(ok, "pipeline run should complete (\(st.lastOutcome ?? ""))")
    let clusters = try store.clusters()
    print("    clusters: " + clusters.map { "\($0.autoName) [\(Int($0.totalSeconds / 60))m]" }.joined(separator: " | "))
    expect(clusters.count >= 4 && clusters.count <= 12, "cluster count \(clusters.count)")
    // purity of the unsupervised assignment
    var byCluster: [ClusterID: [Int: Int]] = [:]
    for (cid, truth) in truthByContext {
        if let cl = try store.context(id: cid)?.clusterID { byCluster[cl, default: [:]][truth, default: 0] += 1 }
    }
    let purity = Double(byCluster.values.reduce(0) { $0 + ($1.values.max() ?? 0) }) / Double(truthByContext.count)
    print("    clustering purity: \(purity)")
    expect(purity > 0.85, "purity \(purity)")
    guard let bundle else { expect(false, "no bundle published"); return }
    expect(bundle.student != nil, "student trained")
    // real-time classification of brand-new, unseen contexts (new lecture / new project etc.)
    let classifier = RealtimeClassifier()
    classifier.install(bundle, clusters: try store.clusters(includeArchived: true))
    // each cluster → the true type most of its members belong to (a type may legitimately span several pure clusters)
    let clusterTruth: [ClusterID: Int] = byCluster.mapValues { counts in counts.max { $0.value < $1.value }!.key }
    var correct = 0, total = 0
    for (ti, t) in syntheticTypes.enumerated() {
        for j in 0..<10 {
            let d = synthDescriptor(t, &rng, novelWords: ["unit\(j + 9)", "new\(j)"])
            let ctx = ContextRecord(id: 100_000 + Int64(ti * 100 + j), key: "new-\(ti)-\(j)", bundleID: d.bundleID, appName: d.appName,
                                    title: d.title, host: d.host, urlPath: d.urlPath, clusterID: nil, clusterSource: .none,
                                    clusterConfidence: 0, isPrivate: false, textUpdatedAt: nil, totalSeconds: 60, behavior: d.behavior)
            let cls = classifier.classify(context: ctx, text: d.text, now: Date())
            total += 1
            if let cid = cls.clusterID, clusterTruth[cid] == ti { correct += 1 }
        }
    }
    let acc = Double(correct) / Double(total)
    print("    real-time accuracy on unseen contexts: \(acc)")
    expect(acc > 0.8, "real-time accuracy \(acc)")
    // splitting the largest activity type yields two non-empty types
    if let biggest = try store.clusters().first {
        let before = try store.topContexts(cluster: biggest.id, limit: 1000).count
        let newID = try pipeline.split(cluster: biggest.id)
        expect(newID != nil, "split should create a new activity type")
        if let newID {
            let a = try store.topContexts(cluster: biggest.id, limit: 1000).count
            let b = try store.topContexts(cluster: newID, limit: 1000).count
            print("    split: \(before) windows → \(a) + \(b)")
            expect(a > 0 && b > 0 && a + b == before, "split partitions the windows")
        }
    }
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - Engine integration (simulated tracking → real models → real throttling)

final class RecordingDelegate: FocusEngineDelegate {
    var nudges: [NudgeRequest] = []
    var questions: [QuestionRequest] = []
    var statuses: [LiveStatus] = []
    func engine(_ engine: FocusEngine, didUpdate status: LiveStatus) { statuses.append(status) }
    func engine(_ engine: FocusEngine, nudge: NudgeRequest) { nudges.append(nudge) }
    func engine(_ engine: FocusEngine, ask: QuestionRequest) { questions.append(ask) }
    func engine(_ engine: FocusEngine, learning: LearningStatus) {}
    func engine(_ engine: FocusEngine, phaseChanged: LearningPhase) {}
    func engine(_ engine: FocusEngine, discoveredClusters: [ClusterID]) {}
    func engine(_ engine: FocusEngine, overlayLevel: Double) {}
    func engineClustersChanged(_ engine: FocusEngine) {}
}

test("engine end-to-end: plan → drift → reminder → gradual slowdown of the right process → release on return") {
    let now = Date()
    guard now.minuteOfDay < 23 * 60 else { print("    (skipped close to midnight)"); return }
    let dir = tempDir("engine")
    let paths = AppPaths(support: dir)
    try? FileManager.default.removeItem(at: paths.models)
    try FileManager.default.createSymbolicLink(at: paths.models, withDestinationURL: AppPaths.default.models)
    let settings = SettingsStore(defaults: UserDefaults(suiteName: "tf-engine-\(UUID().uuidString)")!)
    settings.update { $0.llmBackend = .none; $0.strictness = .normal; $0.nudgeStyle = .banner; $0.useAppleScriptForURLs = false }
    let store = try Store(url: paths.database)
    var rng = SeededRandom(seed: 77)
    var devContexts: [ContextID] = []
    for (ci, t) in syntheticTypes.enumerated() {
        for j in 0..<30 {
            let d = synthDescriptor(t, &rng)
            let c = try store.insertContext(key: "\(t.name)-\(j)", bundleID: d.bundleID, appName: d.appName, title: d.title,
                                            host: d.host, urlPath: d.urlPath, docPath: nil, isPrivate: false, now: now)
            let secs = 120 + Double(rng.next() % 1200)
            let f = secs / d.behavior.seconds
            try store.addContextActivity(id: c.id, seconds: secs, keys: d.behavior.keys * f, clicks: d.behavior.clicks * f,
                                         scrolls: d.behavior.scrolls * f, moves: d.behavior.moves * f,
                                         mediaSeconds: d.behavior.mediaSeconds * f, at: now)
            try store.mergeContextText(id: c.id, text: d.text ?? "", now: now)
            if ci == 0 { devContexts.append(c.id) }
        }
    }
    let pipeline = try LearningPipeline(paths: paths, settings: settings, models: ModelManager(paths: paths))
    let sem = DispatchSemaphore(value: 0)
    Task.detached { _ = await pipeline.run(trigger: .manual); sem.signal() }
    sem.wait()
    // the activity type that holds most dev contexts is today's focus
    var votes: [ClusterID: Int] = [:]
    for id in devContexts { if let c = try store.context(id: id)?.clusterID { votes[c, default: 0] += 1 } }
    guard let devCluster = votes.max(by: { $0.value < $1.value })?.key else { expect(false, "no dev cluster"); return }

    let engine = try FocusEngine(paths: paths, settings: settings)
    let rec = RecordingDelegate()
    engine.delegate = rec
    engine.reloadClusters()
    let m = now.minuteOfDay
    engine.savePlan(DayPlan(day: now.dayKey, blocks: [FocusBlock(startMinute: max(0, m - 30), endMinute: min(24 * 60 - 1, m + 45),
                                                                clusterIDs: [devCluster], note: "test")]))
    let busy = try spawnBusyLoop() // stands in for the distracting browser process
    defer { busy.terminate() }
    func feed(_ t: Double, pid: pid_t, bundle: String, app: String, title: String, host: String?, text: String, video: Bool = false) {
        // realistic input: typing while working, almost nothing while a video plays
        let input = video ? InputDelta(keys: 0, clicks: 0, scrolls: 1, moves: 15) : InputDelta(keys: 14, clicks: 1, scrolls: 2, moves: 60)
        let snap = ActivitySnapshot(time: now.addingTimeInterval(t), interval: 4, input: input, secondsSinceInput: video ? 20 : 1,
                                    pid: pid, bundleID: bundle, appName: app, title: title, host: host, text: text,
                                    mediaPlaying: video,
                                    key: ContextNormalizer.key(bundleID: bundle, host: host, path: nil, cleanTitle: title))
        engine.monitor.queue.sync { engine.monitor(engine.monitor, didCapture: snap) }
    }
    let work = (bundle: "com.microsoft.VSCode", app: "Code", title: "refactor swift struct build error", text: "func struct compile merge branch test")
    for i in 0..<12 { feed(Double(i * 4), pid: getpid(), bundle: work.bundle, app: work.app, title: work.title, host: nil, text: work.text) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    expect(rec.statuses.last?.verdict == .onTrack, "work should be on track: \(String(describing: rec.statuses.last?.verdict))")
    var firstThrottleAt: Double?
    var maxLevel = 0.0
    for i in 12..<62 { // 200 s on YouTube
        let t = Double(i * 4)
        feed(t, pid: busy.processIdentifier, bundle: "com.google.Chrome", app: "Google Chrome",
             title: "funny cats compilation prank reaction", host: "youtube.com", text: "funny compilation cats vlog highlights", video: true)
        if engine.throttler.isThrottling(busy.processIdentifier), firstThrottleAt == nil { firstThrottleAt = t - 48 }
        maxLevel = max(maxLevel, engine.throttler.level)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let drift = rec.statuses.last
    print("    drift verdict \(drift?.verdict.rawValue ?? "-") (\(drift?.activityName ?? "-"), conf \(String(format: "%.2f", drift?.confidence ?? 0)), novelty \(String(format: "%.2f", drift?.novelty ?? 0))), nudges \(rec.nudges.count), slowdown from \(firstThrottleAt ?? -1)s, max level \(String(format: "%.2f", maxLevel))")
    expect(drift?.verdict == .offTrack, "YouTube should be off track")
    expect(rec.nudges.count >= 1, "a reminder should have been shown")
    expect(firstThrottleAt != nil && maxLevel > 0.4, "the distracting process should be slowed down progressively")
    let cpuBefore = processCPUTime(busy.processIdentifier)
    usleep(1_000_000)
    let throttledShare = processCPUTime(busy.processIdentifier) - cpuBefore
    feed(62 * 4, pid: getpid(), bundle: work.bundle, app: work.app, title: work.title, host: nil, text: work.text)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    expect(!engine.throttler.isThrottling(busy.processIdentifier), "slowdown must stop when back to work")
    expect(!isStopped(busy.processIdentifier), "process must not stay paused")
    expect(rec.statuses.last?.verdict == .onTrack, "back on track")
    print(String(format: "    CPU share of the distracting process while slowed: %.2f", throttledShare))
    let eps = try store.episodes(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(3600))
    expect(eps.count == 1 && eps.first?.outcome == .returned, "one drift episode that ended with a return: \(eps.map(\.outcome))")
    expect((eps.first?.nudges ?? 0) >= 1 && (eps.first?.maxLevel ?? 0) > 0.3, "episode keeps its nudges/max level: \(eps)")
    // merging the planned activity type into another one must not turn the planned work into "drift"
    if let target = try store.clusters().first(where: { $0.id != devCluster }) {
        engine.mergeCluster(devCluster, into: target.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for k in 0..<3 {
            feed(Double((64 + k) * 4), pid: getpid(), bundle: work.bundle, app: work.app, title: work.title, host: nil, text: work.text)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(rec.statuses.last?.verdict == .onTrack,
               "after merging the planned type, work must stay on track (got \(String(describing: rec.statuses.last?.verdict)))")
    }
    let states = try store.focusStateSeconds(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(3600))
    print("    focus seconds: on \(Int(states[.onTrack] ?? 0)), off \(Int(states[.offTrack] ?? 0))")
    expect((states[.offTrack] ?? 0) > 150 && (states[.onTrack] ?? 0) > 30, "segments recorded")
    engine.throttler.shutdown()
    try? FileManager.default.removeItem(at: dir)
}

print("\n\(passed) passed, \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
