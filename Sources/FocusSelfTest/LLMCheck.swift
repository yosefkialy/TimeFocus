import FocusCore
import FocusML
import Foundation

/// Developer tools:
///   FocusSelfTest --llm-check [modelID]   installs (if needed) the llama.cpp runtime and a catalog model through the app's
///                                         own ModelManager, runs the real LLM tasks against a local llama-server and
///                                         verifies the server is gone afterwards.
///   FocusSelfTest --apple-intelligence    runs the same tasks against Apple Intelligence (on-device FoundationModels).
enum LLMCheck {
    static func run(modelID: String) async {
        let paths = AppPaths.default
        let manager = ModelManager(paths: paths)
        var lastPrint = Date.distantPast
        manager.onProgress = { p in
            if Date().timeIntervalSince(lastPrint) > 5 || p.finished {
                lastPrint = Date()
                print(String(format: "  download %@: %.0f%% (%@)%@", p.modelID, p.fraction * 100,
                             ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file), p.error.map { " error: \($0)" } ?? ""))
            }
        }
        do {
            var bin = manager.llamaServerBinary(settingsPath: "")
            if bin == nil {
                print("installing llama.cpp runtime…")
                bin = try await manager.installLlamaRuntime()
            }
            guard let bin else { print("no llama-server"); return }
            print("llama-server: \(bin.path)")
            guard let model = ModelCatalog.llmModels.first(where: { $0.id == modelID }) else { print("unknown model"); return }
            if !manager.isInstalled(model) {
                print("downloading \(model.title)…")
                try await manager.download(model)
            }
            guard let file = manager.localLLMFile(model) else { return }
            let llm = LlamaServerLLM(binary: bin, model: file)
            let t0 = Date()
            try await llm.prepare()
            print(String(format: "server ready in %.1fs", Date().timeIntervalSince(t0)))
            await exercise(llm)
            llm.shutdown()
            try await Task.sleep(nanoseconds: 3_500_000_000)
            let alive = ProcessTree.allProcesses().contains { $0.name.hasPrefix("llama-server") }
            print(alive ? "✗ llama-server still running" : "llama-server stopped — memory released ✓")
        } catch {
            print("LLM check failed: \(error)")
        }
    }

    static func runAppleIntelligence() async {
        let (available, reason) = AppleIntelligenceLLM.availability()
        print("imported FoundationModels symbols: \(AppleIntelligenceLLM.importedSymbols?.count ?? -1), " +
              "missing on this macOS: \(AppleIntelligenceLLM.missingSymbols?.count ?? -1)")
        for s in AppleIntelligenceLLM.missingSymbols ?? [] { print("  missing \(s)") }
        print("Apple Intelligence: \(reason)")
        guard available else { return }
        await exercise(AppleIntelligenceLLM())
    }

    /// The real LLM tasks of the learning pipeline, on Hebrew and English samples.
    static func exercise(_ llm: ChatLLM) async {
        let samples: [(String, String, String?, String)] = [
            ("Google Chrome", "אלגברה לינארית 1 - הרצאה 5: ערכים עצמיים", "moodle.tau.ac.il", "הגדרה: ערך עצמי של מטריצה A הוא סקלר λ כך שקיים וקטור v שונה מאפס"),
            ("Google Chrome", "Funny cats compilation 2026 - YouTube", "youtube.com", "Subscribe 1.2M views Up next"),
            ("Code", "FocusEngine.swift — time_focus", nil, "func monitor(_ monitor: ActivityMonitor, didCapture snap: ActivitySnapshot)"),
            ("WhatsApp", "WhatsApp", nil, "אמא: מתי אתה מגיע היום? אני: בערב"),
        ]
        for (app, title, host, text) in samples {
            let c = LearningContext(id: 1, bundleID: "x", appName: app, title: title, host: host, urlPath: nil, text: text,
                                    totalSeconds: 600, behavior: BehaviorStats(seconds: 600), meanHour: 11, embedding: nil,
                                    embeddingModel: nil, description: nil, descriptionCategory: nil, descriptionTopic: nil,
                                    descriptionEmbedding: nil, clusterID: nil, clusterSource: .none, clusterConfidence: 0,
                                    isPrivate: false, lastSeen: Date())
            let t = Date()
            do {
                let a = try await LLMTasks.analyze(llm, context: c)
                print(String(format: "  %.1fs  %@ → [%@] %@ / %@", Date().timeIntervalSince(t), String(title.prefix(40)), a.category, a.activity, a.topic))
            } catch {
                print("  analyze failed: \(error)")
            }
        }
        let brief = LLMTasks.ClusterBrief(windows: [("Google Chrome", "אלגברה לינארית - הרצאה 3", "moodle.tau.ac.il", 3.5),
                                                    ("Preview", "תרגיל בית 4 - אלגברה לינארית.pdf", nil, 2.1)],
                                          descriptions: ["studying linear algebra course material"], keywords: ["אלגברה", "לינארית", "הרצאה"])
        do {
            let name = try await LLMTasks.suggestName(llm, brief: brief, language: "he")
            print("  suggested cluster name (he): \(name.name) — \(name.description)")
        } catch {
            print("  suggestName failed: \(error)")
        }
        let options = [LLMTasks.TypeOption(number: 1, name: "עבודה", description: "software development"),
                       LLMTasks.TypeOption(number: 2, name: "לימודים", description: "university linear algebra course"),
                       LLMTasks.TypeOption(number: 3, name: "בידור", description: "YouTube, Netflix")]
        let newUnit = LearningContext(id: 2, bundleID: "x", appName: "Google Chrome", title: "אלגברה לינארית 1 - יחידה 9: מרחבי מכפלה פנימית",
                                      host: "moodle.tau.ac.il", urlPath: nil, text: "מכפלה פנימית, נורמה, אורתוגונליות, גרם-שמידט",
                                      totalSeconds: 300, behavior: BehaviorStats(seconds: 300), meanHour: 15, embedding: nil,
                                      embeddingModel: nil, description: nil, descriptionCategory: nil, descriptionTopic: nil,
                                      descriptionEmbedding: nil, clusterID: nil, clusterSource: .none, clusterConfidence: 0,
                                      isPrivate: false, lastSeen: Date())
        do {
            let r = try await LLMTasks.chooseType(llm, context: newUnit, options: options)
            print("  zero-shot type for a brand-new course unit: \(r.number.map(String.init) ?? "none") (conf \(r.confidence))")
        } catch {
            print("  chooseType failed: \(error)")
        }
    }
}
