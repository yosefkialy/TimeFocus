import Foundation
import FocusTransformer

/// Open-source models the app can download on explicit user request (inbound only — nothing is uploaded).
public struct CatalogModel: Identifiable, Equatable {
    public enum Kind: String { case embedding, llm, ocr }
    public var id: String
    public var kind: Kind
    public var title: String
    public var details: String
    public var approxBytes: Int64
    public var files: [(remote: URL, local: String)]
    public var recommended: Bool

    public static func == (a: CatalogModel, b: CatalogModel) -> Bool { a.id == b.id }

    static func hf(_ repo: String, _ file: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    static func github(_ repo: String, _ file: String) -> URL {
        URL(string: "https://github.com/\(repo)/raw/main/\(file)")!
    }
}

public enum ModelCatalog {
    public static let embeddingModels: [CatalogModel] = [
        CatalogModel(id: "multilingual-e5-small", kind: .embedding, title: "Multilingual E5 Small",
                     details: "מקודד משפטים רב־לשוני (כולל עברית), 384 ממדים. רץ בתוך האפליקציה, רק בזמן שהמחשב פנוי.",
                     approxBytes: 490_000_000,
                     files: ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]
                        .map { (CatalogModel.hf("intfloat/multilingual-e5-small", $0), $0) },
                     recommended: true),
        CatalogModel(id: "paraphrase-multilingual-MiniLM-L12-v2", kind: .embedding, title: "Paraphrase Multilingual MiniLM",
                     details: "חלופה: מאומן על זיהוי פרפרזות ב־50+ שפות.",
                     approxBytes: 490_000_000,
                     files: ["config.json", "model.safetensors", "tokenizer.json"]
                        .map { (CatalogModel.hf("sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2", $0), $0) },
                     recommended: false),
    ]

    public static let llmModels: [CatalogModel] = [
        CatalogModel(id: "gemma-3-4b-it-Q4_K_M", kind: .llm, title: "Gemma 3 4B (Q4)",
                     details: "מודל שפה פתוח של Google עם תמיכה טובה בעברית. ~3.5GB זיכרון בזמן ריצה — רק כשהמחשב פנוי.",
                     approxBytes: 2_490_000_000,
                     files: [(CatalogModel.hf("ggml-org/gemma-3-4b-it-GGUF", "gemma-3-4b-it-Q4_K_M.gguf"), "gemma-3-4b-it-Q4_K_M.gguf")],
                     recommended: true),
        CatalogModel(id: "gemma-3-1b-it-Q4_K_M", kind: .llm, title: "Gemma 3 1B (Q4)",
                     details: "גרסה קלה (~1.2GB זיכרון). איכות נמוכה יותר, מתאימה למחשבים עמוסים.",
                     approxBytes: 806_000_000,
                     files: [(CatalogModel.hf("ggml-org/gemma-3-1b-it-GGUF", "gemma-3-1b-it-Q4_K_M.gguf"), "gemma-3-1b-it-Q4_K_M.gguf")],
                     recommended: false),
        CatalogModel(id: "qwen2.5-3b-instruct-q4_k_m", kind: .llm, title: "Qwen 2.5 3B Instruct (Q4)",
                     details: "מודל פתוח של Alibaba, חזק באנגלית ובקוד.",
                     approxBytes: 2_100_000_000,
                     files: [(CatalogModel.hf("Qwen/Qwen2.5-3B-Instruct-GGUF", "qwen2.5-3b-instruct-q4_k_m.gguf"), "qwen2.5-3b-instruct-q4_k_m.gguf")],
                     recommended: false),
    ]

    /// Tesseract's Hebrew model (Apple's Vision OCR has no Hebrew); the `tesseract` program itself comes from Homebrew.
    public static let hebrewOCR = CatalogModel(
        id: "tesseract-heb", kind: .ocr, title: "Tesseract — עברית",
        details: "מודל זיהוי טקסט (OCR) לעברית, להבנת התוכן שעל המסך גם כשאין לו טקסט נגיש. נדרשת גם התוכנה tesseract (‏brew install tesseract).",
        approxBytes: 3_704_077,
        files: [(CatalogModel.github("tesseract-ocr/tessdata_best", "heb.traineddata"), "heb.traineddata")],
        recommended: true)

    public static var all: [CatalogModel] { embeddingModels + llmModels + [hebrewOCR] }
}

/// Downloads catalog models and the llama.cpp runtime, and reports what is installed.
public final class ModelManager: NSObject, URLSessionDownloadDelegate {
    public struct Progress: Equatable {
        public var modelID: String
        public var fraction: Double
        public var bytes: Int64
        public var total: Int64
        public var error: String?
        public var finished: Bool

        public init(modelID: String, fraction: Double, bytes: Int64, total: Int64, error: String?, finished: Bool) {
            self.modelID = modelID; self.fraction = fraction; self.bytes = bytes; self.total = total
            self.error = error; self.finished = finished
        }
    }

    public var onProgress: ((Progress) -> Void)?
    private let paths: AppPaths
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var active: [Int: (model: String, local: URL, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var currentModel: String?
    private var doneBytes: Int64 = 0
    private var totalBytes: Int64 = 0

    public init(paths: AppPaths) { self.paths = paths }

    public func directory(for m: CatalogModel) -> URL {
        switch m.kind {
        case .embedding: return paths.modelDirectory(m.id)
        case .llm: return paths.models.appendingPathComponent("llm", isDirectory: true)
        case .ocr: return TesseractOCR.modelDirectory(paths)
        }
    }

    public func isInstalled(_ m: CatalogModel) -> Bool {
        let dir = directory(for: m)
        return m.files.allSatisfy { f in
            let url = dir.appendingPathComponent(f.local)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return size > 0
        }
    }

    public func localLLMFile(_ m: CatalogModel) -> URL? {
        guard m.kind == .llm, let f = m.files.first else { return nil }
        return directory(for: m).appendingPathComponent(f.local)
    }

    public func installedLLMs() -> [CatalogModel] { ModelCatalog.llmModels.filter(isInstalled) }

    public func delete(_ m: CatalogModel) {
        let dir = directory(for: m)
        for f in m.files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f.local)) }
        if m.kind == .embedding { try? FileManager.default.removeItem(at: dir) }
    }

    /// Downloads every file of a catalog model (user-initiated).
    public func download(_ m: CatalogModel) async throws {
        let dir = directory(for: m)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        currentModel = m.id
        doneBytes = 0
        totalBytes = m.approxBytes
        defer { currentModel = nil }
        do {
            for f in m.files {
                let dest = dir.appendingPathComponent(f.local)
                if let size = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64, size > 0 {
                    doneBytes += size
                    continue
                }
                try await downloadFile(f.remote, to: dest, modelID: m.id)
            }
            onProgress?(Progress(modelID: m.id, fraction: 1, bytes: totalBytes, total: totalBytes, error: nil, finished: true))
        } catch {
            onProgress?(Progress(modelID: m.id, fraction: 0, bytes: 0, total: totalBytes, error: "\(error.localizedDescription)", finished: true))
            throw error
        }
    }

    private func downloadFile(_ remote: URL, to local: URL, modelID: String) async throws {
        guard remote.scheme == "https" else { throw URLError(.badURL) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: remote)
            lock.lock(); active[task.taskIdentifier] = (modelID, local, c); lock.unlock()
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let entry = active[downloadTask.taskIdentifier]
        lock.unlock()
        guard let entry else { return }
        let done = doneBytes + totalBytesWritten
        let total = max(totalBytes, done)
        onProgress?(Progress(modelID: entry.model, fraction: Double(done) / Double(max(total, 1)), bytes: done, total: total,
                             error: nil, finished: false))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let entry = active.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        do {
            try? FileManager.default.removeItem(at: entry.local)
            try FileManager.default.moveItem(at: location, to: entry.local)
            let size = (try? FileManager.default.attributesOfItem(atPath: entry.local.path)[.size] as? Int64) ?? 0
            doneBytes += size
            entry.continuation.resume()
        } catch {
            entry.continuation.resume(throwing: error)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let entry = active.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        entry?.continuation.resume(throwing: error)
    }

    // MARK: llama.cpp runtime

    public func llamaServerBinary(settingsPath: String) -> URL? {
        LlamaServerLLM.locateBinary(settingsPath: settingsPath, paths: paths)
    }

    /// Downloads the official prebuilt llama.cpp release for Apple Silicon from GitHub into the app's folder.
    public func installLlamaRuntime() async throws -> URL {
        let api = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var assetURL: URL?
        var assetName = ""
        for r in releases {
            for a in (r["assets"] as? [[String: Any]]) ?? [] {
                let name = a["name"] as? String ?? ""
                if name.contains("bin-macos-arm64"), name.hasSuffix(".tar.gz") || name.hasSuffix(".zip"),
                   let s = a["browser_download_url"] as? String, let u = URL(string: s), u.host == "github.com" {
                    assetURL = u; assetName = name; break
                }
            }
            if assetURL != nil { break }
        }
        guard let url = assetURL else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        let archive = paths.runtime.appendingPathComponent(assetName)
        currentModel = "llama-runtime"
        doneBytes = 0
        totalBytes = 30_000_000
        try await downloadFile(url, to: archive, modelID: "llama-runtime")
        currentModel = nil
        let dest = paths.runtime.appendingPathComponent("llama.cpp", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        if assetName.hasSuffix(".zip") {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", archive.path, dest.path]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            p.arguments = ["-xzf", archive.path, "-C", dest.path]
        }
        try p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        guard p.terminationStatus == 0, let bin = LlamaServerLLM.findExecutable(named: "llama-server", under: dest) else {
            throw URLError(.cannotDecodeContentData)
        }
        onProgress?(Progress(modelID: "llama-runtime", fraction: 1, bytes: 1, total: 1, error: nil, finished: true))
        Log.info("llama.cpp runtime installed: \(assetName)", "learning")
        return bin
    }
}
