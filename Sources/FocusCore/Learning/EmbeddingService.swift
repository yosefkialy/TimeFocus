import Foundation
import FocusML
import FocusTransformer

/// A sentence-embedding "teacher". Heavy providers are loaded only while the Mac is idle and unloaded right after.
public protocol EmbeddingProvider: AnyObject {
    var modelID: String { get }
    var dimension: Int { get }
    /// Embeds a small batch (≤16) of texts; returns L2-normalised vectors.
    func embed(_ texts: [String]) throws -> [[Float]]
    func unload()
}

/// Multilingual transformer encoder (e.g. multilingual-e5-small) running in-process via FocusTransformer.
public final class TransformerEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let dimension: Int
    private let directory: URL
    private var encoder: SentenceEncoder?
    private let prefix: String

    public init(directory: URL, modelID: String, dimension: Int = 384) {
        self.directory = directory
        self.modelID = modelID
        self.dimension = dimension
        prefix = modelID.contains("e5") ? "query: " : ""
    }

    public static func isInstalled(at dir: URL) -> Bool {
        SentenceEncoderFiles.required.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private func loaded() throws -> SentenceEncoder {
        if let e = encoder { return e }
        let e = try SentenceEncoder(directory: directory)
        encoder = e
        Log.info("sentence encoder loaded (\(modelID), \(e.approximateMemoryBytes / 1_000_000) MB mapped)", "learning")
        return e
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        let enc = try loaded()
        return try enc.encode(texts.map { prefix + $0 }, maxTokens: 128)
    }

    public func unload() {
        if encoder != nil { Log.info("sentence encoder unloaded", "learning") }
        encoder = nil
    }
}

/// Always-available fallback (no model download needed).
public final class HashingEmbeddingProvider: EmbeddingProvider {
    public let modelID = HashingEmbedder.modelID
    public let dimension = 384
    private let embedder = HashingEmbedder(dimension: 384)
    public init() {}
    public func embed(_ texts: [String]) throws -> [[Float]] { texts.map { embedder.embed($0) } }
    public func unload() {}
}

public enum EmbeddingProviders {
    /// Picks the configured transformer if its files are present, otherwise the hashing fallback.
    public static func make(settings: AppSettings, paths: AppPaths) -> EmbeddingProvider {
        let dir = paths.modelDirectory(settings.embeddingModelID)
        if TransformerEmbeddingProvider.isInstalled(at: dir) {
            return TransformerEmbeddingProvider(directory: dir, modelID: settings.embeddingModelID)
        }
        return HashingEmbeddingProvider()
    }

    /// Text the teacher sees for one context (kept short: ~128 tokens).
    public static func document(for c: LearningContext) -> String {
        var parts: [String] = [c.appName]
        if !c.title.isEmpty { parts.append(c.title) }
        if let h = c.host { parts.append(h) }
        if let p = c.urlPath {
            let toks = TextTokenizer.pathTokens(p, maxSegments: 3)
            if !toks.isEmpty { parts.append(toks.joined(separator: " ")) }
        }
        var doc = parts.joined(separator: " | ")
        if let t = c.text, !t.isEmpty {
            let snippet = t.split(whereSeparator: \.isNewline).prefix(12).joined(separator: " · ")
            doc += " | " + String(snippet.prefix(500))
        }
        return doc
    }
}
