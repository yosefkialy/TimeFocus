import Foundation
import FocusML

/// Turns raw window information into a stable "context" identity. Unread counters, app-name suffixes and
/// notification dots are removed so that "WhatsApp (3)" and "WhatsApp (4)" are the same context.
public enum ContextNormalizer {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.operasoftware.Opera", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen", "org.chromium.Chromium", "com.kagi.kagimacOS",
    ]

    public static func isBrowser(_ bundleID: String) -> Bool { browserBundleIDs.contains(bundleID) }

    private static let browserSuffixes = [
        "Google Chrome", "Mozilla Firefox", "Firefox", "Microsoft Edge", "Brave", "Safari", "Arc", "Vivaldi", "Opera",
        "Chromium", "Zen Browser", "Firefox Developer Edition",
    ]

    private static let leadingNoise = try! NSRegularExpression(pattern: #"^\s*(?:[\(\[]\s*[\d,\.]+\+?\s*[\)\]]|[•●◉○\*])\s*"#)
    private static let inlineCounters = try! NSRegularExpression(pattern: #"\s*[\(\[]\s*[\d,\.]+\+?\s*(?:unread|new|חדשות|חדש)?\s*[\)\]]"#, options: .caseInsensitive)
    private static let audioSuffix = try! NSRegularExpression(pattern: #"\s*[-–—]\s*(Audio playing|Camera or microphone recording|Playing|מושמע אודיו)\s*$"#, options: .caseInsensitive)
    private static let spaces = try! NSRegularExpression(pattern: #"\s+"#)

    private static func replace(_ re: NSRegularExpression, _ s: String, _ with: String = "") -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// Display/identity title with app suffixes and volatile counters removed.
    public static func cleanTitle(_ title: String, appName: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t = replace(audioSuffix, t)
        for _ in 0..<2 { t = replace(leadingNoise, t) }
        t = replace(inlineCounters, t)
        let suffixes = [appName] + browserSuffixes
        for s in suffixes where !s.isEmpty {
            for sep in [" - ", " — ", " – ", " | "] {
                if let r = t.range(of: sep + s, options: [.backwards, .caseInsensitive]) {
                    // strip "… - Google Chrome" and "… - Google Chrome - Profile"
                    if t.distance(from: r.upperBound, to: t.endIndex) < 40 { t = String(t[..<r.lowerBound]) }
                }
            }
        }
        t = replace(spaces, t, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(200))
    }

    public static func isPrivateWindowTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("private browsing") || lower.contains("incognito") || lower.contains("inprivate")
            || title.contains("גלישה פרטית") || title.contains("גלישה בסתר")
    }

    /// Host (without "www.") and path of a URL string (the address bar may omit the scheme).
    public static func parseURL(_ raw: String?) -> (host: String?, path: String?) {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return (nil, nil) }
        if !s.contains("://") { s = "https://" + s }
        guard let comps = URLComponents(string: s), let h = comps.host?.lowercased(), !h.isEmpty else { return (nil, nil) }
        let host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        let path = comps.path.isEmpty || comps.path == "/" ? nil : String(comps.path.prefix(200))
        return (host, path)
    }

    /// First path segment — distinguishes e.g. docs.google.com/document vs /spreadsheets without over-splitting.
    public static func pathHead(_ path: String?) -> String {
        guard let p = path else { return "" }
        return p.split(separator: "/").first.map { String($0.prefix(40)).lowercased() } ?? ""
    }

    public static func key(bundleID: String, host: String?, path: String?, cleanTitle: String) -> String {
        let t = cleanTitle.lowercased()
        let raw = "\(bundleID)|\(host ?? "")|\(pathHead(path))|\(t)"
        return String(fnv1a64(raw), radix: 36) + ":" + String(fnv1a64(raw, salt: 99), radix: 36)
    }

    /// Masks obviously sensitive tokens before anything is stored (emails, long digit runs such as card numbers).
    public static func redact(_ text: String) -> String {
        var t = text
        let patterns = [
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            #"\b\d(?:[ -]?\d){11,18}\b"#,
            #"\b\d{9}\b"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) { t = replace(re, t, "•••") }
        }
        return t
    }
}
