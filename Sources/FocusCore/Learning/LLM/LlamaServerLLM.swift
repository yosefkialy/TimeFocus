import Darwin
import Foundation

/// Runs an open-source GGUF model with llama.cpp's `llama-server`, bound to 127.0.0.1 only.
/// The server process exists only while the Mac is idle; `shutdown()` kills it and returns all RAM.
/// Its pid is recorded in a file so a leftover server (after a crash or a forced quit) is stopped by the watchdog
/// and at the next launch.
public final class LlamaServerLLM: ChatLLM {
    public let binary: URL
    public let model: URL
    public let port: Int
    private let pidFile: URL?
    private var process: Process?
    private let lock = NSLock()

    public var id: String { "llama:\(model.deletingPathExtension().lastPathComponent)" }
    public var displayName: String { model.deletingPathExtension().lastPathComponent }

    /// - Parameter port: defaults to a per-process port so a stray server can never be mistaken for ours.
    public init(binary: URL, model: URL, pidFile: URL? = nil, port: Int? = nil) {
        self.binary = binary
        self.model = model
        self.pidFile = pidFile
        self.port = port ?? (18_765 + Int(getpid() % 700))
    }

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public static func pidFile(in paths: AppPaths) -> URL { paths.runtime.appendingPathComponent("llama-server.pid") }

    /// Stops a llama-server left behind by a previous run (only if the recorded pid really is a llama-server).
    public static func killLeftover(pidFile: URL) {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        if let path = ProcessTree.executablePath(pid), path.hasSuffix("llama-server") {
            kill(pid, SIGTERM)
            usleep(800_000)
            if ProcessTree.bsd(pid) != nil { kill(pid, SIGKILL) }
            Log.info("stopped a leftover llama-server (pid \(pid))", "learning")
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// Finds a llama-server binary: explicit path, the app's own runtime folder, then Homebrew locations.
    public static func locateBinary(settingsPath: String, paths: AppPaths) -> URL? {
        var candidates: [String] = []
        if !settingsPath.isEmpty { candidates.append(settingsPath) }
        if let found = findExecutable(named: "llama-server", under: paths.runtime) { candidates.append(found.path) }
        candidates += ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func findExecutable(named name: String, under dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == name && FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    public func prepare() async throws {
        if isRunning, await LocalOnly.get(base.appendingPathComponent("health")) == 200 { return }
        if let pidFile { Self.killLeftover(pidFile: pidFile) }
        try start()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            guard isRunning else { throw LLMError.unavailable("llama-server exited during start-up") }
            if await LocalOnly.get(base.appendingPathComponent("health"), timeout: 2) == 200 { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        shutdown()
        throw LLMError.timeout
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    private func start() throws {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { return }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw LLMError.unavailable("llama-server not found") }
        guard FileManager.default.fileExists(atPath: model.path) else { throw LLMError.unavailable("model file missing") }
        let p = Process()
        p.executableURL = binary
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-c", "4096", "-ngl", "99",
                       "-np", "1", "-t", String(threads)]
        var env = ProcessInfo.processInfo.environment
        env["LLAMA_ARG_HOST"] = "127.0.0.1"
        p.environment = env
        p.currentDirectoryURL = binary.deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .utility
        try p.run()
        process = p
        if let pidFile {
            try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        }
        Log.info("llama-server started (pid \(p.processIdentifier), port \(port), model \(model.lastPathComponent))", "learning")
    }

    public func complete(system: String, user: String, maxTokens: Int, jsonMode: Bool) async throws -> String {
        guard isRunning else { throw LLMError.unavailable("llama-server not running") }
        let client = OpenAICompatibleLLM(baseURL: base.appendingPathComponent("v1"), model: "local")
        return try await client.complete(system: system, user: user, maxTokens: maxTokens, jsonMode: jsonMode)
    }

    /// Kills the server (idempotent, callable from any thread — e.g. the moment the user comes back).
    public func shutdown() {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p else { return }
        if p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
            Log.info("llama-server stopped — memory released", "learning")
        }
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
    }

    deinit { shutdown() }
}
