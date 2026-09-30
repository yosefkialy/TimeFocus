import Foundation
import FocusML

/// A local chat-completion model. Implementations must keep every byte on this Mac.
public protocol ChatLLM: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Loads the model / starts its local server. Called only while the Mac is idle.
    func prepare() async throws
    func complete(system: String, user: String, maxTokens: Int, jsonMode: Bool) async throws -> String
    /// Frees all memory used by the model (kills the local server, unloads weights).
    func shutdown()
}

public enum LLMError: Error, CustomStringConvertible {
    case unavailable(String)
    case notLocal(String)
    case badResponse(String)
    case timeout
    public var description: String {
        switch self {
        case .unavailable(let s): return "LLM unavailable: \(s)"
        case .notLocal(let s): return "Refusing non-local LLM endpoint: \(s)"
        case .badResponse(let s): return "Bad LLM response: \(s)"
        case .timeout: return "LLM timeout"
        }
    }
}

/// Abstract description of one activity, produced by the LLM at idle time.
public struct ActivityAnalysis: Equatable {
    public var activity: String
    public var category: String
    public var topic: String
}

/// Prompt templates + robust JSON parsing shared by all LLM backends.
public enum LLMTasks {
    public static let categories = [
        "software development", "writing", "studying / coursework", "reading / research", "email", "chat / messaging",
        "meetings / calls", "planning / management", "design / creative", "data / spreadsheets", "finance / admin",
        "shopping", "news", "social media", "video / entertainment", "music / audio", "gaming", "system / utilities", "other",
    ]

    static func describe(_ c: LearningContext, textChars: Int = 700) -> String {
        var lines = ["App: \(c.appName)"]
        if !c.title.isEmpty { lines.append("Window title: \(c.title)") }
        if let h = c.host { lines.append("Website: \(h)\(c.urlPath.map { " (path: \(String($0.prefix(80))))" } ?? "")") }
        if let t = c.text, !t.isEmpty {
            let snippet = t.split(whereSeparator: \.isNewline).prefix(20).joined(separator: " · ")
            lines.append("Visible text (excerpt): \(String(snippet.prefix(textChars)))")
        }
        let b = c.behavior
        var habits: [String] = []
        if b.keysPerMin > 40 { habits.append("lots of typing") } else if b.keysPerMin < 3 { habits.append("almost no typing") }
        if b.scrollsPerMin > 20 { habits.append("scrolling/reading") }
        if b.mediaFraction > 0.4 { habits.append("video/media playing") }
        if !habits.isEmpty { lines.append("Observed behaviour: \(habits.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    public static func analyze(_ llm: ChatLLM, context c: LearningContext) async throws -> ActivityAnalysis {
        let system = """
        You label computer activity for a private, on-device focus assistant. You see ONE window the user spent time in.
        Describe the KIND of activity abstractly, so windows of the same kind of work get the same description even when
        their specific content differs (a new lecture of the same course, a new ticket of the same job). Content may be in
        Hebrew or any language; always answer in English. Reply with a single JSON object and nothing else.
        """
        let user = """
        \(describe(c))

        Return JSON: {"activity": "<what the user is doing, 3-10 words>", "category": "<exactly one of: \(categories.joined(separator: "; "))>", "topic": "<main subject, 1-5 words>"}
        """
        let raw = try await llm.complete(system: system, user: user, maxTokens: 120, jsonMode: true)
        guard let obj = extractJSON(raw) else { throw LLMError.badResponse(String(raw.prefix(200))) }
        let activity = (obj["activity"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var category = (obj["category"] as? String ?? "other").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !categories.contains(category) {
            category = categories.first { category.contains($0.components(separatedBy: " /").first ?? $0) } ?? "other"
        }
        let topic = (obj["topic"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !activity.isEmpty else { throw LLMError.badResponse("empty activity") }
        return ActivityAnalysis(activity: String(activity.prefix(120)), category: category, topic: String(topic.prefix(60)))
    }

    public struct ClusterBrief {
        public var windows: [(app: String, title: String, host: String?, hours: Double)]
        public var descriptions: [String]
        public var keywords: [String]
        public init(windows: [(app: String, title: String, host: String?, hours: Double)], descriptions: [String], keywords: [String]) {
            self.windows = windows; self.descriptions = descriptions; self.keywords = keywords
        }
    }

    /// Suggests a short human name for an activity cluster in the UI language.
    public static func suggestName(_ llm: ChatLLM, brief: ClusterBrief, language: String) async throws -> (name: String, description: String) {
        let langName = language.hasPrefix("he") ? "Hebrew" : "English"
        let windows = brief.windows.prefix(12).map { w in
            "- \(w.app): \(String(w.title.prefix(90)))\(w.host.map { " [\($0)]" } ?? "") — \(String(format: "%.1f", w.hours))h"
        }.joined(separator: "\n")
        let user = """
        These windows were automatically grouped as ONE type of computer activity:
        \(windows)
        \(brief.descriptions.isEmpty ? "" : "Typical descriptions: " + brief.descriptions.prefix(8).joined(separator: "; "))
        \(brief.keywords.isEmpty ? "" : "Keywords: " + brief.keywords.prefix(10).joined(separator: ", "))

        Give this activity type a short, clear name (1-3 words) and a one-sentence description, both in \(langName).
        Return JSON: {"name": "...", "description": "..."}
        """
        let system = "You name groups of computer activities for a personal focus app. Always write in \(langName). Reply with JSON only."
        func ask(_ prompt: String) async throws -> (String, String) {
            let raw = try await llm.complete(system: system, user: prompt, maxTokens: 120, jsonMode: true)
            guard let obj = extractJSON(raw), let name = obj["name"] as? String, !name.isEmpty else {
                throw LLMError.badResponse(String(raw.prefix(200)))
            }
            return (String(name.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines),
                    String((obj["description"] as? String ?? "").prefix(200)))
        }
        var result = try await ask(user)
        // small models sometimes ignore the language: retry once, then keep whatever we got
        let isHebrew: (String) -> Bool = { $0.unicodeScalars.contains { (0x05D0...0x05EA).contains($0.value) } }
        if language.hasPrefix("he"), !isHebrew(result.0),
           let retry = try? await ask(user + "\nIMPORTANT: the name and the description MUST be written in Hebrew (עברית).") {
            if isHebrew(retry.0) { result = retry }
        }
        return result
    }

    public struct TypeOption {
        public var number: Int
        public var name: String
        public var description: String
        public init(number: Int, name: String, description: String) { self.number = number; self.name = name; self.description = description }
    }

    /// Zero-shot: which known activity type does a new window belong to? Returns the option number or nil.
    public static func chooseType(_ llm: ChatLLM, context c: LearningContext, options: [TypeOption]) async throws -> (number: Int?, confidence: Double) {
        let list = options.map { "\($0.number). \($0.name) — \($0.description)" }.joined(separator: "\n")
        let user = """
        The user's known activity types:
        \(list)

        A new activity:
        \(describe(c, textChars: 500))

        Which activity type does the new activity belong to? Judge by the KIND of activity, not exact words.
        If none fits well, answer 0. Return JSON: {"type": <number>, "confidence": <0.0-1.0>}
        """
        let raw = try await llm.complete(system: "You classify computer activities for a personal focus app. Reply with JSON only.",
                                         user: user, maxTokens: 40, jsonMode: true)
        guard let obj = extractJSON(raw) else { throw LLMError.badResponse(String(raw.prefix(200))) }
        let n = (obj["type"] as? NSNumber)?.intValue ?? Int(obj["type"] as? String ?? "") ?? 0
        let conf = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.5
        guard n > 0, options.contains(where: { $0.number == n }) else { return (nil, conf) }
        return (n, conf)
    }

    /// Finds and parses the first JSON object in a model reply (tolerates ```json fences and chatter).
    public static func extractJSON(_ s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = s.index(after: i)
        }
        guard let e = end, let data = String(s[start...e]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Refuses any network destination that is not this machine.
public enum LocalOnly {
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    /// POSTs JSON to a loopback URL.
    static func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval = 180) async throws -> [String: Any] {
        guard isLoopback(url) else { throw LLMError.notLocal(url.absoluteString) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.badResponse("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse("not JSON") }
        return obj
    }

    static func get(_ url: URL, timeout: TimeInterval = 3) async -> Int? {
        guard isLoopback(url) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        guard let (_, resp) = try? await session.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}

/// Any OpenAI-compatible server running on this Mac (llama.cpp, Ollama, LM Studio…).
public final class OpenAICompatibleLLM: ChatLLM {
    public let baseURL: URL
    public let model: String
    public var id: String { "openai:\(model)@\(baseURL.host ?? "")" }
    public var displayName: String { "\(model) (local server)" }

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public func prepare() async throws {
        guard LocalOnly.isLoopback(baseURL) else { throw LLMError.notLocal(baseURL.absoluteString) }
        guard await LocalOnly.get(baseURL.appendingPathComponent("models")) != nil else {
            throw LLMError.unavailable("no server at \(baseURL.absoluteString)")
        }
    }

    public func complete(system: String, user: String, maxTokens: Int, jsonMode: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        let obj = try await LocalOnly.postJSON(baseURL.appendingPathComponent("chat/completions"), body: body)
        guard let choices = obj["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw LLMError.badResponse("no choices") }
        return content
    }

    /// Ollama keeps models in RAM for minutes; ask it to unload right away.
    public func shutdown() {
        guard baseURL.port == 11434, var root = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        root.path = "/api/generate"
        guard let url = root.url else { return }
        let model = self.model
        Task { _ = try? await LocalOnly.postJSON(url, body: ["model": model, "keep_alive": 0], timeout: 10) }
    }
}
