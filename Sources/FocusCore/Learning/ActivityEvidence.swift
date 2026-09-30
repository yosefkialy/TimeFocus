import Foundation
import FocusML

/// Where the app saw a keyword.
public struct EvidenceSources: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Text visible in the window (Accessibility, or OCR when enabled).
    public static let text = EvidenceSources(rawValue: 1 << 0)
    /// The window title.
    public static let title = EvidenceSources(rawValue: 1 << 1)
    /// The website address (host and path).
    public static let address = EvidenceSources(rawValue: 1 << 2)
    /// The topic the local LLM gave the window.
    public static let model = EvidenceSources(rawValue: 1 << 3)
}

public struct EvidenceTerm: Hashable {
    public var term: String
    public var sources: EvidenceSources
    /// In how many windows of the activity type the word appears (1 for a single window's terms).
    public var windows: Int
}

/// What the app knows about one window, for the user to check.
public struct WindowEvidence: Identifiable, Equatable {
    public var id: ContextID
    public var clusterID: ClusterID?
    public var bundleID: String
    public var appName: String
    public var title: String
    /// False when the title only repeats the app or site name — e.g. every conversation in the Claude app is titled
    /// "Claude", so everything done in it is one window and only its text tells the activities apart.
    public var hasInformativeTitle: Bool
    public var host: String?
    public var urlPath: String?
    public var seconds: Double
    public var activity: String?
    public var category: String?
    public var topic: String?
    public var assignment: AssignmentSource
    public var confidence: Double
    /// Words that set this window apart from the other windows (title, address and screen text).
    public var terms: [EvidenceTerm]
    /// The first lines of the stored window text, as read from the screen (emails and card numbers already masked).
    public var textLines: [String]
}

public struct DescriptionShare: Equatable {
    public var activity: String
    public var topic: String?
    public var seconds: Double
}

public struct CategoryShare: Equatable {
    public var category: String
    public var share: Double
}

/// Why the app groups these windows together, in words a person can check.
public struct ClusterEvidence: Equatable {
    public var clusterID: ClusterID?
    /// Words from the text read off the screen that set this activity type apart from the others.
    public var textTerms: [EvidenceTerm]
    /// Words from window titles and website addresses (hosts are kept whole).
    public var addressTerms: [EvidenceTerm]
    /// What the local LLM said the windows are, by time spent.
    public var descriptions: [DescriptionShare]
    /// The LLM's categories, as shares of the described time.
    public var categories: [CategoryShare]
    public var behavior: BehaviorStats
    /// Hour of the day the type is typically used (nil when its use is spread over the day).
    public var typicalHour: Double?
    /// Heaviest first (at most the number the query loaded).
    public var windows: [WindowEvidence]
    /// All windows of the type, including those not loaded.
    public var totalWindows: Int
    /// Best keywords across all sources — stored on the cluster and given to the LLM when it names the type.
    public var keywords: [String]
}

public struct ActivityEvidenceSnapshot: Equatable {
    public var clusters: [ClusterID: ClusterEvidence] = [:]
    public var unassigned: ClusterEvidence?
    public init() {}
}

/// Human-readable evidence for activity types: the words the app saw (window text, titles, website addresses), what
/// the local LLM understood about each window, and how each window got its type — so the user can tell what a type
/// really is before naming, splitting or merging it.
///
/// Keywords are class-based TF-IDF per source (words frequent in one type and rare in the others). Interface text is
/// kept out with display-only stopwords (Hebrew and English — the student network's tokenizer is left untouched),
/// common interface words, words an app shows in every one of its windows (sidebars, toolbars), a lower weight for
/// one- and two-word lines (menus, status lines), accessibility descriptions of icons, the app's own name and
/// saturated counts. Hebrew words with a one-letter prefix ("באפליקציה") are counted under their base word.
public enum ActivityEvidence {
    private static let text = 0, title = 1, address = 2, model = 3
    private static let sourceFlags: [EvidenceSources] = [.text, .title, .address, .model]

    /// False when a title says nothing beyond the app or site name, is empty, or is only generic words ("Open",
    /// "Untitled", "New Tab").
    public static func isInformativeTitle(_ title: String, appName: String, host: String?) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, t != appName.lowercased() else { return false }
        if let h = host?.lowercased(), t == h || t == "www." + h { return false }
        return !surfaceWords(t).allSatisfy { isStopword($0.key) || genericTitleWords.contains($0.key) }
    }

    private static let genericTitleWords: Set<String> = [
        "open", "save", "untitled", "tab", "window", "settings", "preferences", "search", "loading", "document", "file",
        "ללא", "כותרת", "חדש", "חדשה", "פתח", "שמור", "הגדרות", "חיפוש",
    ]

    public static func build(_ rows: [EvidenceRow], groupTerms: Int = 10, addressTerms addressLimit: Int = 8,
                             windowTerms: Int = 8, textLines: Int = 14) -> ActivityEvidenceSnapshot {
        guard !rows.isEmpty else { return ActivityEvidenceSnapshot() }

        // 1. raw tokens per window and source
        struct Token {
            let key: String; let surface: String; let weight: Float; let isHost: Bool
            var joined = false // only spaces since the previous word of the same line
            var line = 0       // identifies the text line (the same line in several windows is one piece of evidence)
        }
        var raw: [[[Token]]] = []
        var vocabulary = Set<String>()
        raw.reserveCapacity(rows.count)
        for r in rows {
            var perSource = [[Token]](repeating: [], count: 4)
            if let t = r.text {
                for line in t.split(whereSeparator: \.isNewline) {
                    let words = surfaceWords(line)
                    guard !words.isEmpty, !isIconDescription(words) else { continue }
                    let w = lineWeight(words.count), id = line.hashValue
                    perSource[text] += words.map { Token(key: $0.key, surface: $0.surface, weight: w, isHost: false, joined: $0.joined, line: id) }
                }
            }
            if isInformativeTitle(r.title, appName: r.appName, host: r.host) {
                perSource[title] = surfaceWords(r.title).map { Token(key: $0.key, surface: $0.surface, weight: 1, isHost: false, joined: $0.joined) }
            }
            if let h = r.host?.lowercased(), !h.isEmpty {
                perSource[address].append(Token(key: h, surface: h, weight: 1, isHost: true))
            }
            if let p = r.urlPath {
                perSource[address] += pathWords(p).map { Token(key: $0.key, surface: $0.surface, weight: 0.8, isHost: false) }
            }
            if let topic = r.topic {
                perSource[model] = surfaceWords(topic).map { Token(key: $0.key, surface: $0.surface, weight: 1, isHost: false) }
            }
            for s in perSource { for t in s where !t.isHost { vocabulary.insert(t.key) } }
            raw.append(perSource)
        }

        // 2. Hebrew prefixes: "באפליקציה" and "האפליקציה" count as "אפליקציה" when the base word appears on its own,
        //    or when two prefixed forms share it and one of them is "ה" + base (the definite article).
        var prefixedForms: [String: Int] = [:]
        var withArticle = Set<String>()
        for k in vocabulary {
            guard let base = hebrewBases(k).first else { continue }
            prefixedForms[base, default: 0] += 1
            if k.hasPrefix("ה") { withArticle.insert(base) }
        }
        func isBase(_ b: String) -> Bool { vocabulary.contains(b) || ((prefixedForms[b] ?? 0) >= 2 && withArticle.contains(b)) }
        var canonical: [String: String] = [:]
        for k in vocabulary {
            if let base = hebrewBases(k).reversed().first(where: isBase) { canonical[k] = base }
        }
        func canon(_ k: String) -> String {
            var k = k
            for _ in 0..<2 { guard let next = canonical[k] else { break }; k = next }
            return k
        }

        // 3. per-window term weights
        var terms = [[[String: Float]]](repeating: [[:], [:], [:], [:]], count: rows.count)
        var surfaces: [String: [String: Int]] = [:]
        for (i, perSource) in raw.enumerated() {
            // the app's own name says nothing new next to its icon ("Claude" in the Claude app)
            let appWords = Set(surfaceWords(rows[i].appName).map(\.key))
            for s in 0..<4 {
                for t in perSource[s] {
                    let key = t.isHost ? t.key : canon(t.key)
                    guard t.isHost ? isDisplayableHost(key) : (isDisplayable(key, source: s) && !appWords.contains(key)) else { continue }
                    terms[i][s][key, default: 0] += t.weight
                    surfaces[key, default: [:]][key == t.key ? t.surface : key, default: 0] += 1
                }
            }
        }

        // 4. interface text of an app: words in most of its windows, across different types, say nothing about any
        //    type (words shared only by windows of one type are that type's content)
        var byApp: [String: [Int]] = [:]
        for (i, r) in rows.enumerated() where !terms[i][text].isEmpty { byApp[r.bundleID, default: []].append(i) }
        for (_, idx) in byApp where idx.count >= 2 && Set(idx.map { rows[$0].clusterID }).count >= 2 {
            var df: [String: Int] = [:]
            var groupsOf: [String: Set<ClusterID?>] = [:]
            for i in idx {
                for k in terms[i][text].keys { df[k, default: 0] += 1; groupsOf[k, default: []].insert(rows[i].clusterID) }
            }
            let minDF = max(2, Int((0.6 * Double(idx.count)).rounded(.up)))
            let chrome = df.filter { $0.value >= minDF && (groupsOf[$0.key]?.count ?? 0) >= 2 }.map(\.key)
            for i in idx { for k in chrome { terms[i][text][k] = nil } }
        }

        // 5. saturate counts: a word on every line of a window counts about twice, not ten times
        for i in terms.indices { for s in 0..<4 { terms[i][s] = terms[i][s].mapValues { $0 * 2.2 / ($0 + 1.2) } } }

        func display(_ key: String) -> String {
            guard let forms = surfaces[key], !forms.isEmpty else { return key }
            return forms.max { a, b in
                if a.value != b.value { return a.value < b.value }
                let ua = a.key.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
                let ub = b.key.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
                return ua != ub ? ua < ub : a.key > b.key
            }!.key
        }

        /// Joins ranked words that nearly always stand side by side in these windows ("iCloud" + "Drive" →
        /// "iCloud Drive", "אלגברה" + "לינארית"), keeping the rank of the better word; at most three words. Once in a
        /// title or address is enough; in window text the pair must appear in two different lines (one sentence, even
        /// when several windows show it, is not a phrase).
        func joinPhrases(_ keys: [String], windows: [Int], sources: [Int]) -> [(display: String, keys: [String])] {
            let wanted = Set(keys)
            var occurrences: [String: Int] = [:]
            var pairs: [String: [String: Int]] = [:]
            var strength: [String: Int] = [:] // title/address pairs 2, text pairs 1 per distinct line
            var countedLines = Set<String>()
            var pairSurfaces: [String: [String: Int]] = [:]
            for i in windows {
                for s in sources {
                    var prev: (key: String, surface: String)? = nil
                    for t in raw[i][s] {
                        let k = t.isHost ? t.key : canon(t.key)
                        guard wanted.contains(k) else { prev = nil; continue }
                        occurrences[k, default: 0] += 1
                        if t.joined, let p = prev, p.key != k {
                            pairs[p.key, default: [:]][k, default: 0] += 1
                            if s != text {
                                strength[p.key + "\u{1}" + k, default: 0] += 2
                            } else if countedLines.insert(p.key + "\u{1}" + k + "\u{1}" + String(t.line)).inserted {
                                strength[p.key + "\u{1}" + k, default: 0] += 1
                            }
                            pairSurfaces[p.key + "\u{1}" + k, default: [:]][p.surface + " " + t.surface, default: 0] += 1
                        }
                        prev = (k, t.surface)
                    }
                }
            }
            var next: [String: String] = [:], previous: [String: String] = [:]
            for (a, followers) in pairs {
                guard let best = followers.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { continue }
                let b = best.key, c = best.value
                guard (strength[a + "\u{1}" + b] ?? 0) >= 2,
                      Double(c) >= 0.7 * Double(min(occurrences[a] ?? 0, occurrences[b] ?? 0)) else { continue }
                if let rival = previous[b], (pairs[rival]?[b] ?? 0) > c || ((pairs[rival]?[b] ?? 0) == c && rival < a) { continue }
                if let rival = previous[b] { next[rival] = nil }
                next[a] = b; previous[b] = a
            }
            func surface(_ a: String, _ b: String) -> String {
                pairSurfaces[a + "\u{1}" + b]?.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? display(a) + " " + display(b)
            }
            var used = Set<String>()
            var out: [(display: String, keys: [String])] = []
            for k in keys where !used.contains(k) {
                var head = k
                for _ in 0..<2 { if let p = previous[head], !used.contains(p) { head = p } }
                var chain = [head]
                while chain.count < 3, let nx = next[chain.last!], !used.contains(nx), !chain.contains(nx) { chain.append(nx) }
                if !chain.contains(k) { chain = [k] }
                used.formUnion(chain)
                switch chain.count {
                case 1: out.append((display(k), chain))
                case 2: out.append((surface(chain[0], chain[1]), chain))
                default:
                    let tail = surface(chain[1], chain[2]).split(separator: " ").last.map(String.init) ?? display(chain[2])
                    out.append((surface(chain[0], chain[1]) + " " + tail, chain))
                }
            }
            return out
        }

        // 6. per activity type: class-based TF-IDF per source
        let groups: [ClusterID?] = Array(Set(rows.map(\.clusterID))).sorted { ($0 ?? -1) < ($1 ?? -1) }
        let groupIndex = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1, $0) })
        var agg = [[[String: Float]]](repeating: [[:], [:], [:], [:]], count: groups.count)
        var windowsWith = [[String: Int]](repeating: [:], count: groups.count)
        var sourcesOf = [[String: EvidenceSources]](repeating: [:], count: groups.count)
        var members = [[Int]](repeating: [], count: groups.count)
        for (i, r) in rows.enumerated() {
            let g = groupIndex[r.clusterID]!
            members[g].append(i)
            let w = Float(max(r.seconds, 1).squareRoot())
            var seen = Set<String>()
            for s in 0..<4 {
                for (k, v) in terms[i][s] {
                    agg[g][s][k, default: 0] += w * v
                    sourcesOf[g][k, default: []].insert(sourceFlags[s])
                    if seen.insert(k).inserted { windowsWith[g][k, default: 0] += 1 }
                }
            }
        }
        let textScores = KeywordExtractor.scores(agg.map { $0[text] })
        let addressScores = KeywordExtractor.scores(agg.map { $0[title].merging($0[address], uniquingKeysWith: +) })
        let modelScores = KeywordExtractor.scores(agg.map { $0[model] })

        // 7. per window: words that set it apart from all other windows
        var docFreq: [String: Int] = [:]
        for t in terms {
            var seen = Set<String>()
            for s in [text, title, address] { for k in t[s].keys where seen.insert(k).inserted { docFreq[k, default: 0] += 1 } }
        }
        let n = Float(rows.count)
        func windowEvidence(_ i: Int) -> WindowEvidence {
            let r = rows[i]
            var score: [String: Float] = [:]
            var from: [String: EvidenceSources] = [:]
            for (s, w) in [(text, Float(1)), (title, 1.2), (address, 1)] {
                for (k, v) in terms[i][s] {
                    let idf = log((n + 1) / (Float(docFreq[k] ?? 0) + 0.5)) + 0.1
                    score[k, default: 0] += w * v * idf
                    from[k, default: []].insert(sourceFlags[s])
                }
            }
            let lines = (r.text ?? "").split(whereSeparator: \.isNewline)
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(200)) }.filter { !$0.isEmpty }
            return WindowEvidence(
                id: r.id, clusterID: r.clusterID, bundleID: r.bundleID, appName: r.appName, title: r.title,
                hasInformativeTitle: isInformativeTitle(r.title, appName: r.appName, host: r.host), host: r.host,
                urlPath: r.urlPath, seconds: r.seconds, activity: r.activity?.nonEmpty, category: r.category?.nonEmpty,
                topic: r.topic?.nonEmpty, assignment: r.assignment, confidence: r.confidence,
                terms: joinPhrases(Array(ranked(score).prefix(windowTerms + 4)), windows: [i], sources: [title, text, address])
                    .prefix(windowTerms)
                    .map { p in EvidenceTerm(term: p.display, sources: p.keys.reduce([]) { $0.union(from[$1] ?? []) }, windows: 1) },
                textLines: Array(lines.prefix(textLines)))
        }

        var snapshot = ActivityEvidenceSnapshot()
        for (g, gid) in groups.enumerated() {
            func term(_ p: (display: String, keys: [String])) -> EvidenceTerm {
                EvidenceTerm(term: p.display, sources: p.keys.reduce([]) { $0.union(sourcesOf[g][$1] ?? []) },
                             windows: p.keys.map { windowsWith[g][$0] ?? 0 }.min() ?? 0)
            }
            let addrKeys = Array(ranked(addressScores[g]).prefix(addressLimit + 4))
            let addr = joinPhrases(addrKeys, windows: members[g], sources: [title, address]).prefix(addressLimit)
            let shown = Set(addr.flatMap(\.keys))
            let txt = joinPhrases(Array(ranked(textScores[g]).filter { !shown.contains($0) }.prefix(groupTerms + 5)),
                                  windows: members[g], sources: [text]).prefix(groupTerms)

            // keywords across sources: per-source scores normalised to the type's best word, weighted by how clean the source is
            var combined: [String: Float] = [:]
            for (scores, w) in [(textScores[g], Float(0.8)), (addressScores[g], 1), (modelScores[g], 0.9)] {
                guard let top = scores.values.max(), top > 0 else { continue }
                for (k, v) in scores where v > 0 { combined[k, default: 0] += w * v / top }
            }

            let idx = members[g].sorted { rows[$0].seconds != rows[$1].seconds ? rows[$0].seconds > rows[$1].seconds : rows[$0].id < rows[$1].id }
            var descriptions: [String: DescriptionShare] = [:]
            var best: [String: Double] = [:]
            var categories: [String: Double] = [:]
            var described = 0.0
            var behavior = BehaviorStats()
            var hs = 0.0, hc = 0.0
            for i in idx {
                let r = rows[i]
                if let a = r.activity?.nonEmpty {
                    let key = a.lowercased()
                    var d = descriptions[key] ?? DescriptionShare(activity: a, topic: nil, seconds: 0)
                    d.seconds += r.seconds
                    if r.seconds > best[key] ?? -1 { best[key] = r.seconds; d.topic = r.topic?.nonEmpty }
                    descriptions[key] = d
                }
                if let c = r.category?.nonEmpty { categories[c, default: 0] += r.seconds; described += r.seconds }
                behavior.seconds += r.behavior.seconds
                behavior.keys += r.behavior.keys
                behavior.clicks += r.behavior.clicks
                behavior.scrolls += r.behavior.scrolls
                behavior.moves += r.behavior.moves
                behavior.mediaSeconds += r.behavior.mediaSeconds
                hs += r.hourSin; hc += r.hourCos
            }
            var typicalHour: Double? = nil
            if behavior.seconds > 0, (hs * hs + hc * hc).squareRoot() / behavior.seconds >= 0.5 {
                let h = atan2(hs, hc) * 24 / (2 * .pi)
                typicalHour = h < 0 ? h + 24 : h
            }
            let evidence = ClusterEvidence(
                clusterID: gid,
                textTerms: txt.map(term),
                addressTerms: addr.map(term),
                descriptions: descriptions.values.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.activity < $1.activity }
                    .prefix(4).map { $0 },
                categories: categories.filter { described > 0 && $0.value / described >= 0.1 }
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(3).map { CategoryShare(category: $0.key, share: $0.value / described) },
                behavior: behavior,
                typicalHour: typicalHour,
                windows: idx.map(windowEvidence),
                totalWindows: max(idx.count, idx.map { rows[$0].groupWindows }.max() ?? 0),
                keywords: ranked(combined).prefix(8).map(display))
            if let gid { snapshot.clusters[gid] = evidence } else { snapshot.unassigned = evidence }
        }
        return snapshot
    }

    // MARK: - scoring

    /// Keys by descending score, with a mild preference for longer (more specific) words; ties by key, so the screen
    /// does not reshuffle between refreshes.
    private static func ranked(_ scores: [String: Float]) -> [String] {
        scores.compactMap { k, v -> (String, Float)? in
            v > 0 ? (k, v * (0.85 + 0.03 * Float(min(k.unicodeScalars.count, 10)))) : nil
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        .map(\.0)
    }

    /// Menus, sidebars and status lines are mostly one or two words; sentences are content.
    private static func lineWeight(_ words: Int) -> Float {
        switch words {
        case ...1: return 0.35
        case 2: return 0.5
        case 3...4: return 0.75
        default: return 1
        }
    }

    // MARK: - tokens

    private static let alphanumerics = CharacterSet.alphanumerics
    private static let digits = CharacterSet.decimalDigits

    @inline(__always)
    private static func isHebrewLetter(_ u: Unicode.Scalar) -> Bool { (0x05D0...0x05EA).contains(u.value) }

    /// Words with their spelling as shown and a lower-cased key — the same word rules as `TextTokenizer.words`
    /// (Hebrew niqqud dropped, geresh/gershayim inside a Hebrew word joined: צה"ל → צהל), except that the Hebrew
    /// hyphen (maqaf) separates words. `joined`: only spaces separate the word from the previous one (phrases).
    static func surfaceWords<S: StringProtocol>(_ text: S) -> [(key: String, surface: String, joined: Bool)] {
        var out: [(key: String, surface: String, joined: Bool)] = []
        var current = String.UnicodeScalarView()
        var onlySpaces = false // since the previous word
        func flush() {
            guard !current.isEmpty else { return }
            let s = String(current)
            current.removeAll(keepingCapacity: true)
            out.append((s.lowercased(), s, onlySpaces && !out.isEmpty))
            onlySpaces = true
        }
        for u in text.unicodeScalars {
            if u.value == 0x05BE { flush(); onlySpaces = false; continue }
            if (0x0591...0x05C7).contains(u.value) { continue }
            if alphanumerics.contains(u) || u == "_" {
                current.append(u)
            } else if u == "'" || u == "\"" || u == "״" || u == "׳", let last = current.last, isHebrewLetter(last) {
                continue
            } else {
                flush()
                if u != " " && u != "\u{00A0}" && u != "\t" { onlySpaces = false }
            }
        }
        flush()
        return out
    }

    /// The word without one or two leading prefix letters (ו/ה/ב/ל/ש), longest first. "מ" and "כ" are left alone:
    /// too many nouns start with them ("מספר" is not "מ" + "ספר").
    static func hebrewBases(_ w: String) -> [String] {
        let u = Array(w.unicodeScalars)
        guard u.count >= 4, isHebrewLetter(u[0]) else { return [] }
        var out: [String] = []
        var i = 0
        while i < 2, u.count - i >= 4, [0x05D5, 0x05D4, 0x05D1, 0x05DC, 0x05E9].contains(u[i].value) { // ו ה ב ל ש
            i += 1
            out.append(String(String.UnicodeScalarView(u[i...])))
        }
        return out
    }

    /// Accessibility descriptions of icons ("App Store letter A icon", "Small circle badge, filled") — not content.
    private static func isIconDescription(_ words: [(key: String, surface: String, joined: Bool)]) -> Bool {
        words.count <= 8 && words.contains { iconWords.contains($0.key) }
    }

    private static let iconWords: Set<String> = [
        "icon", "badge", "circle", "rectangle", "symbol", "arrow", "chevron", "filled", "glyph", "סמל", "אייקון", "סמליל",
    ]

    /// Readable words of a URL path, skipping ids ("/chat/3f2a9c1e-…" → "chat").
    static func pathWords(_ path: String) -> [(key: String, surface: String)] {
        var out: [(key: String, surface: String)] = []
        for segment in path.split(separator: "/").prefix(4) {
            let s = String(segment).removingPercentEncoding ?? String(segment)
            if !looksLikeID(s) { out += surfaceWords(s).map { ($0.key, $0.surface) } }
        }
        return out
    }

    static func looksLikeID(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count >= 8 else { return false }
        let digitCount = u.filter { digits.contains($0) }.count
        let hex = u.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) || $0 == "-" }
        return (hex && digitCount >= 2) || Double(digitCount) / Double(u.count) > 0.4 || u.count >= 40
    }

    static func isDisplayable(_ key: String, source: Int) -> Bool {
        let u = key.unicodeScalars
        guard u.count >= 2, u.count <= 30, let first = u.first, !digits.contains(first) else { return false }
        var digitCount = 0, letters = 0
        for c in u { if digits.contains(c) { digitCount += 1 } else if c != "_" { letters += 1 } }
        guard letters > 0, digitCount < 4, !(digitCount >= 2 && digitCount * 3 > u.count) else { return false }
        if isStopword(key) { return false }
        if source == text || source == address, interfaceWords.contains(key) { return false } // "/course/view.php"
        return true
    }

    private static func isDisplayableHost(_ host: String) -> Bool {
        guard let first = host.unicodeScalars.first, !digits.contains(first) else { return false } // raw IPs
        return host.count <= 60
    }

    static func isStopword(_ key: String) -> Bool {
        if TextTokenizer.isStopword(key) || extraStopwords.contains(key) { return true }
        // a function word behind a one-letter prefix is still one: "ואני", "שזה", "כשאני"
        return TextTokenizer.hebrewVariants(key).contains { TextTokenizer.isStopword($0) || extraStopwords.contains($0) }
    }

    /// Function words beyond the tokenizer's own lists (display only; the student network's features do not use these).
    static let extraStopwords: Set<String> = [
        "its", "they", "them", "their", "there", "here", "these", "those", "has", "have", "had", "having", "been", "being",
        "were", "am", "would", "should", "could", "may", "might", "must", "shall", "just", "also", "only", "very", "much",
        "many", "most", "some", "such", "each", "every", "both", "other", "others", "another", "than", "too", "again",
        "still", "yet", "now", "well", "even", "ever", "never", "always", "often", "because", "while", "where", "though",
        "although", "after", "before", "during", "since", "until", "under", "above", "below", "between", "through",
        "without", "within", "across", "around", "off", "onto", "like", "get", "gets", "got", "make", "makes", "made",
        "see", "look", "want", "need", "know", "think", "let", "lets", "go", "going", "goes", "come", "take", "give",
        "say", "said", "says", "one", "two", "three", "first", "last", "way", "thing", "things", "something", "anything",
        "nothing", "everything", "lot", "lots", "sure", "ok", "okay", "don", "doesn", "didn", "isn", "aren", "wasn",
        "won", "cannot", "couldn", "shouldn", "wouldn", "ll", "ve", "re", "he", "she", "him", "her", "his", "us",
        "whose", "whom", "else", "own", "same", "few", "able", "hi", "hello", "thanks", "thank", "please",
        "עכשיו", "ממש", "רוצה", "רוצים", "צריך", "צריכה", "צריכים", "אפשר", "יכול", "יכולה", "יכולים", "כבר", "יותר",
        "פחות", "מאוד", "קצת", "הרבה", "כאן", "פה", "שם", "אז", "הנה", "אחרי", "לפני", "תוך", "בתוך", "כמה", "איזה",
        "איזו", "אלה", "אלו", "אותם", "אותן", "אותי", "אותך", "אותנו", "לי", "לך", "לו", "לה", "לנו", "לכם", "להם",
        "להן", "בו", "בה", "בהם", "בי", "בך", "שלנו", "שלכם", "שלהם", "שלהן", "הייתה", "יהיה", "תהיה", "זהו", "זוהי",
        "כלומר", "למשל", "בגלל", "לכן", "כדי", "אולי", "בערך", "בכלל", "שוב", "עדיין", "תמיד", "אף", "פעם", "באמת",
        "טוב", "בסדר", "נכון", "אלא", "אך", "אנו", "הזו", "האלה", "ההוא", "ההיא", "מאשר", "עבור", "בשביל", "לגבי",
        "אצל", "ליד", "מול", "תחת", "מעל", "מתחת", "דרך", "לפי", "בלי", "ללא", "איפה", "מתי", "כיצד", "אתם", "אתן",
        "וגם", "ומה", "ולא", "וזה", "ויש", "ואין", "ואם", "ועוד", "אלי", "אליך", "אליו", "אליה", "אלינו", "אליהם",
        "לבד", "לבדי", "לבדו", "לבדה", "אמור", "אמורה", "אמורים", "עצמי", "עצמו", "עצמה", "עצמם", "שום", "משהו", "מישהו",
        "כלום", "הכל", "הכול", "כולם", "כולו", "כולה", "איך", "שלום", "תודה", "בבקשה",
    ]

    /// Words of the interface itself (buttons, status lines, time stamps) — ignored in window text and URL paths, but
    /// not in titles, so a page titled "Search engines" still shows "search".
    static let interfaceWords: Set<String> = [
        "menu", "file", "edit", "view", "window", "help", "search", "settings", "preferences", "share", "close", "open",
        "save", "cancel", "done", "apply", "back", "forward", "reload", "refresh", "bookmark", "bookmarks", "tab", "tabs",
        "sidebar", "toolbar", "button", "icon", "image", "badge", "circle", "arrow", "arrows", "filled", "fill",
        "rectangle", "symbol", "chevron", "small", "large", "more", "less", "options", "option", "sign", "log", "login",
        "logout", "account", "profile", "notifications", "notification", "loading", "untitled", "press", "enter",
        "escape", "esc", "click", "tap", "select", "selected", "key", "keys", "copy", "paste", "undo", "redo", "delete",
        "remove", "add", "show", "hide", "expand", "collapse", "minimize", "maximize", "zoom", "scroll", "drag", "drop",
        "ago", "min", "mins", "minute", "minutes", "hour", "hours", "sec", "secs", "second", "seconds", "am", "pm",
        "today", "yesterday", "tomorrow", "thinking", "tokens", "responding", "typing", "online", "offline",
        "delivered", "mode", "chat", "chats", "reply", "send", "sent",
        "חיפוש", "חפש", "הגדרות", "שיתוף", "שתף", "סגור", "סגירה", "פתח", "פתיחה", "שמור", "שמירה", "ביטול", "בטל",
        "אישור", "אשר", "חזרה", "חזור", "קדימה", "תפריט", "אפשרויות", "התחבר", "התחברות", "התנתק", "התנתקות",
        "חשבון", "פרופיל", "התראות", "התראה", "טוען", "טעינה", "העתק", "העתקה", "הדבק", "מחק", "מחיקה", "הוסף",
        "הוספה", "הצג", "הסתר", "לחץ", "לחצו", "בחר", "בחרו", "דקות", "דקה", "שעות", "שעה", "שניות", "שנייה", "היום",
        "אתמול", "מחר", "ערוך", "עריכה", "הורד", "הורדה", "שלח", "שליחה", "הודעה", "הודעות", "צאט", "תגובה", "הגב",
        "מקליד", "מקלידה", "מחובר", "מחוברת",
    ]
}

private extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
