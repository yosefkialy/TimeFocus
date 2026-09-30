import Foundation
import FocusML

/// The idle-time learning pipeline. Every heavy model (transformer encoder, LLM) is loaded only inside a run
/// and released at the end of its stage; a run is cancelled the moment the user touches the Mac again.
///
///  A. teacher embeddings of new/changed contexts          (multilingual transformer, in-process)
///  B. abstract activity descriptions                        (local LLM)
///  C. embeddings of those descriptions                      (transformer)
///  D. clustering (learning phase) / prototype assignment    (pure math)
///  E. zero-shot assignment of novel contexts + type names   (local LLM)
///  F. discovery of new activity types, cluster metadata
///  G. training of the real-time student network             (distillation + classification)
///  H. publish a new model bundle to the real-time classifier
public final class LearningPipeline {
    public enum Trigger { case idle, manual }

    private let paths: AppPaths
    private let settings: SettingsStore
    private let models: ModelManager
    /// Connection owned by the running pipeline (only touched while holding run ownership).
    private let store: Store
    /// Separate connection for status/phase queries that may come from any thread (serialised by `statsLock`).
    private let statsStore: Store
    private let statsLock = NSLock()
    private let runLock = NSLock()
    private var currentFlag: CancellationFlag?
    private var activeLLM: ChatLLM?
    private let statusLock = NSLock()
    private var _status = LearningStatus()

    /// Called (any thread) whenever the status changes.
    public var onStatus: ((LearningStatus) -> Void)?
    /// Called (any thread) with a freshly built model bundle.
    public var onBundle: ((ModelBundle) -> Void)?
    /// Called when the phase changes (e.g. collecting → naming).
    public var onPhaseChange: ((LearningPhase) -> Void)?
    /// Called when brand-new activity types were discovered after the naming phase.
    public var onNewClusters: (([ClusterID]) -> Void)?

    static let minContextSeconds: Double = 10
    static let phaseKey = "learning.phase"

    public init(paths: AppPaths, settings: SettingsStore, models: ModelManager) throws {
        self.paths = paths
        self.settings = settings
        self.models = models
        store = try Store(url: paths.database)
        statsStore = try Store(url: paths.database)
        var st = LearningStatus()
        let storedPhase = (try? store.string(Self.phaseKey)) ?? nil
        st.phase = storedPhase.flatMap { LearningPhase(rawValue: $0) } ?? .collecting
        if let last = try? store.string("learning.lastRun"), let t = Double(last) { st.lastRun = Date(timeIntervalSince1970: t) }
        if let meta = store.codable(ModelBundle.metaKey, as: BundleMeta.self) { st.embeddingModel = meta.embeddingModel }
        if let r = store.codable("learning.lastReport", as: StudentTrainingReport.self) {
            st.studentAccuracy = r.validationAccuracy
            st.studentSemanticCosine = r.validationSemanticCosine
        }
        _status = st
    }

    public var status: LearningStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }

    private func update(_ change: (inout LearningStatus) -> Void) {
        statusLock.lock()
        change(&_status)
        let s = _status
        statusLock.unlock()
        onStatus?(s)
    }

    public var isRunning: Bool { runLock.lock(); defer { runLock.unlock() }; return currentFlag != nil }

    /// Stops the current run. The local LLM server (if any) is killed right away, so its memory is returned
    /// immediately instead of after the current request.
    public func cancel() {
        runLock.lock(); let f = currentFlag; let llm = activeLLM; runLock.unlock()
        f?.cancel()
        llm?.shutdown()
    }

    private func setActiveLLM(_ llm: ChatLLM?) {
        runLock.lock(); activeLLM = llm; runLock.unlock()
    }

    public var phase: LearningPhase { status.phase }

    public func setPhase(_ p: LearningPhase) {
        statsLock.lock()
        try? statsStore.setString(Self.phaseKey, p.rawValue)
        statsLock.unlock()
        update { $0.phase = p }
        onPhaseChange?(p)
    }

    /// Recomputes counters/readiness without running any model (cheap; for the UI; any thread).
    public func refreshCounts() {
        let s = settings.current
        let model = status.embeddingModel
        statsLock.lock()
        let counts = (try? statsStore.counts(model: model.isEmpty ? nil : model)) ?? Store.Counts()
        statsLock.unlock()
        let readiness = computeReadiness(settings: s)
        update { $0.counts = counts; $0.readiness = readiness }
    }

    private func computeReadiness(settings s: AppSettings) -> LearningReadiness {
        statsLock.lock(); defer { statsLock.unlock() }
        let days = ((try? statsStore.activeSecondsPerDay(days: 60)) ?? []).filter { $0.seconds >= 1800 }.count
        let hours = ((try? statsStore.counts(model: nil)) ?? Store.Counts()).trackedSeconds / 3600
        let clusters = ((try? statsStore.clusters()) ?? []).count
        return LearningReadiness(daysWithData: days, hoursTracked: hours, requiredDays: s.minLearningDays,
                                 requiredHours: s.minLearningHours, clusterCount: clusters)
    }

    // MARK: - Run

    /// Runs the whole pipeline. Returns true if it completed without cancellation.
    private func beginRun() -> CancellationFlag? {
        runLock.lock(); defer { runLock.unlock() }
        if currentFlag != nil { return nil }
        let flag = CancellationFlag()
        currentFlag = flag
        return flag
    }

    private func endRun() {
        runLock.lock(); currentFlag = nil; let llm = activeLLM; activeLLM = nil; runLock.unlock()
        llm?.shutdown()
    }

    @discardableResult
    public func run(trigger: Trigger) async -> Bool {
        guard let flag = beginRun() else { return false }
        defer { endRun() }

        let started = Date()
        update { $0.running = true; $0.stage = .embedding; $0.progress = 0; $0.detail = ""; $0.newClusters = [] }
        Log.info("learning run started (\(trigger == .idle ? "idle" : "manual"))", "learning")
        var ok = false
        do {
            ok = try await runStages(flag: flag)
        } catch {
            Log.error("learning run failed: \(error)", "learning")
            update { $0.stage = .failed; $0.lastOutcome = "\(error)" }
        }
        let secs = Date().timeIntervalSince(started)
        if ok { try? store.setString("learning.lastRun", String(Date().timeIntervalSince1970)) }
        update {
            $0.running = false
            $0.lastRunSeconds = secs
            if ok { $0.lastRun = Date(); $0.stage = .finished; $0.lastOutcome = "ok" }
            else if flag.isCancelled { $0.stage = .cancelled; $0.lastOutcome = "cancelled" }
            $0.progress = ok ? 1 : $0.progress
        }
        refreshCounts()
        Log.info("learning run \(ok ? "finished" : "stopped") in \(Int(secs))s", "learning")
        return ok
    }

    private func runStages(flag: CancellationFlag) async throws -> Bool {
        let s = settings.current
        let now = Date()
        try store.purgeText(olderThan: now.addingTimeInterval(-Double(s.textRetentionDays) * 86400))
        try store.purgeSegments(olderThan: now.addingTimeInterval(-Double(s.segmentRetentionDays) * 86400))

        // A. teacher embeddings
        let provider = EmbeddingProviders.make(settings: s, paths: paths)
        update { $0.embeddingModel = provider.modelID }
        if (try? store.string("emb.model")) ?? nil != provider.modelID {
            try store.clearDescriptionEmbeddings()
            try store.setString("emb.model", provider.modelID)
        }
        guard try embedContexts(provider, flag: flag) else { provider.unload(); return false }
        // zero-shot semantic anchors (only meaningful for a real neural encoder)
        let anchors: [[Float]] = provider is TransformerEmbeddingProvider
            ? ((try? CategoryAnchors.embeddings(provider: provider, store: store)) ?? []) : []

        // B. abstract descriptions with the local LLM
        let llm = makeLLM(settings: s)
        setActiveLLM(llm)
        update { $0.llmName = llm?.displayName }
        if let llm {
            provider.unload() // never hold the encoder and the LLM in RAM at the same time
            guard try await describeContexts(llm, flag: flag, limit: s.maxLLMCallsPerRun) else { llm.shutdown(); return false }
            llm.shutdown()
        }

        // C. description embeddings
        guard try embedDescriptions(provider, flag: flag) else { provider.unload(); return false }
        provider.unload()

        // D–F. clustering / assignment / discovery
        update { $0.stage = .clustering; $0.detail = ""; $0.progress = 0.6 }
        let contexts = try store.learningContexts(minSeconds: Self.minContextSeconds, limit: 3000)
            .filter { $0.embeddingModel == provider.modelID && $0.embedding?.count == provider.dimension }
        guard contexts.count >= 8 else {
            update { $0.detail = "not enough data yet (\(contexts.count) activities)" }
            return !flag.isCancelled
        }
        var builder = RepresentationBuilder()
        let calibration = CategoryAnchors.calibrate(contexts.compactMap(\.embedding), anchors: anchors)
        let inputs = contexts.map { representationInput($0, anchors: anchors, calibration: calibration) }
        let weights = contexts.map { Float(max($0.totalSeconds, 1).squareRoot()) }
        builder.fit(inputs, weights: weights)
        let reps = smoothWithCoUsage(contexts: contexts, reps: inputs.map { builder.represent($0) })

        var newClusterIDs: [ClusterID] = []
        if phase == .collecting {
            try fullClustering(contexts: contexts, reps: reps, weights: weights)
        } else {
            newClusterIDs = try await incrementalAssignment(contexts: contexts, reps: reps, weights: weights,
                                                            llm: llm, flag: flag)
        }
        if flag.isCancelled { llm?.shutdown(); return false }
        try refreshClusterMetadata()
        if let llm { try await suggestNames(llm, flag: flag, language: s.interfaceLanguage) }
        llm?.shutdown()
        if flag.isCancelled { return false }

        // G. prototypes + student network
        update { $0.stage = .training; $0.detail = ""; $0.progress = 0.8 }
        let refreshed = try store.learningContexts(ids: contexts.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        let clusters = try store.clusters()
        let classIDs = clusters.map(\.id)
        let classIndex = Dictionary(uniqueKeysWithValues: classIDs.enumerated().map { ($1, $0) })
        var protoVecs: [[Float]] = [], protoW: [Float] = [], protoL: [Int] = []
        for (i, c) in contexts.enumerated() {
            guard let cid = byID[c.id]?.clusterID, let li = classIndex[cid] else { continue }
            protoVecs.append(reps[i]); protoW.append(weights[i]); protoL.append(li)
        }
        let prototypes = PrototypeIndex.build(vectors: protoVecs, weights: protoW, labels: protoL, classIDs: classIDs)
        let student = try trainStudent(contexts: refreshed, classIDs: classIDs, teacherDim: provider.dimension, flag: flag)
        if flag.isCancelled { return false }

        // H. publish
        let prevVersion = store.codable(ModelBundle.metaKey, as: BundleMeta.self)?.version ?? 0
        let meta = BundleMeta(version: prevVersion + 1, embeddingModel: provider.modelID, semanticDim: provider.dimension,
                              prototypes: prototypes, representation: builder, builtAt: Date(),
                              anchors: anchors.isEmpty ? nil : anchors, anchorCalibration: calibration)
        let bundle = ModelBundle(meta: meta, student: student, clusters: clusters)
        bundle.save(store: store, paths: paths)
        onBundle?(bundle)
        update {
            $0.studentAccuracy = student?.lastReport?.validationAccuracy
            $0.studentSemanticCosine = student?.lastReport?.validationSemanticCosine
            if let r = student?.lastReport { try? store.setCodable("learning.lastReport", r) }
            $0.newClusters = newClusterIDs
        }
        if !newClusterIDs.isEmpty { onNewClusters?(newClusterIDs) }

        // phase transition: enough data → ask the user to name the activity types
        let readiness = computeReadiness(settings: s)
        update { $0.readiness = readiness }
        if phase == .collecting && readiness.isReady { setPhase(.naming) }
        return true
    }

    // MARK: - Stage A/C

    private func embedContexts(_ provider: EmbeddingProvider, flag: CancellationFlag) throws -> Bool {
        let todo = try store.contextsNeedingEmbedding(model: provider.modelID, minSeconds: Self.minContextSeconds, limit: 6000)
        update { $0.stage = .embedding; $0.detail = "\(todo.count)"; $0.progress = 0 }
        var done = 0
        for batch in todo.chunked(into: 16) {
            if flag.isCancelled { return false }
            let vecs = try provider.embed(batch.map(EmbeddingProviders.document))
            try store.db.transaction {
                for (c, v) in zip(batch, vecs) { try store.saveEmbedding(id: c.id, vector: v, model: provider.modelID, now: Date()) }
            }
            done += batch.count
            let p = Double(done) / Double(max(todo.count, 1))
            update { $0.progress = 0.3 * p; $0.detail = "\(done)/\(todo.count)" }
        }
        return true
    }

    private func embedDescriptions(_ provider: EmbeddingProvider, flag: CancellationFlag) throws -> Bool {
        let todo = try store.contextsNeedingDescriptionEmbedding(limit: 6000)
        guard !todo.isEmpty else { return true }
        update { $0.stage = .embedding; $0.detail = "descriptions \(todo.count)" }
        for batch in todo.chunked(into: 16) {
            if flag.isCancelled { return false }
            let vecs = try provider.embed(batch.map(\.1))
            try store.db.transaction {
                for (item, v) in zip(batch, vecs) { try store.saveDescriptionEmbedding(id: item.0, vector: v) }
            }
        }
        return true
    }

    // MARK: - Stage B

    public func makeLLM(settings s: AppSettings) -> ChatLLM? {
        func llama() -> ChatLLM? {
            guard let bin = models.llamaServerBinary(settingsPath: s.llamaServerPath) else { return nil }
            let installed = models.installedLLMs()
            let chosen = installed.first { $0.id == s.llmModelFile } ?? installed.first { $0.recommended } ?? installed.first
            guard let m = chosen, let file = models.localLLMFile(m) else { return nil }
            return LlamaServerLLM(binary: bin, model: file, pidFile: LlamaServerLLM.pidFile(in: paths))
        }
        func openai() -> ChatLLM? {
            guard let u = URL(string: s.openAIBaseURL), LocalOnly.isLoopback(u) else { return nil }
            return OpenAICompatibleLLM(baseURL: u, model: s.openAIModel)
        }
        switch s.llmBackend {
        case .none: return nil
        case .appleIntelligence: return AppleIntelligenceLLM.availability().0 ? AppleIntelligenceLLM() : nil
        case .llamaServer: return llama()
        case .openAICompatible: return openai()
        case .automatic:
            if AppleIntelligenceLLM.availability().0 { return AppleIntelligenceLLM() }
            return llama()
        }
    }

    private func describeContexts(_ llm: ChatLLM, flag: CancellationFlag, limit: Int) async throws -> Bool {
        let todo = try store.contextsNeedingDescription(minSeconds: 45, limit: limit)
        guard !todo.isEmpty else { return true }
        update { $0.stage = .describing; $0.detail = "starting \(llm.displayName)"; $0.progress = 0.3 }
        do {
            try await llm.prepare()
        } catch {
            Log.error("LLM unavailable: \(error)", "learning")
            update { $0.llmNote = "\(error)" }
            return true
        }
        var failures = 0
        for (i, c) in todo.enumerated() {
            if flag.isCancelled { return false }
            do {
                let a = try await LLMTasks.analyze(llm, context: c)
                try store.saveDescription(id: c.id, description: a.activity, category: a.category, topic: a.topic,
                                          model: llm.id, now: Date())
            } catch {
                failures += 1
                try? store.markDescriptionAttempted(id: c.id, now: Date())
                if failures >= 8 && failures > i / 2 {
                    update { $0.llmNote = "LLM keeps failing: \(error)" }
                    break
                }
            }
            update { $0.detail = "\(i + 1)/\(todo.count)"; $0.progress = 0.3 + 0.25 * Double(i + 1) / Double(todo.count) }
        }
        return true
    }

    // MARK: - Stage D (learning phase): full unsupervised clustering with stable ids

    private func fullClustering(contexts: [LearningContext], reps: [[Float]], weights: [Float]) throws {
        let n = contexts.count
        let maxK = min(n > 600 ? 12 : 10, max(3, n / 3))
        let result = AutoCluster.run(vectors: reps, weights: weights, kRange: 3...max(3, maxK), minShare: 0.015)
        let old = try store.clusters(includeArchived: false)
        let userNamedIDs = Set(old.filter(\.userNamed).map(\.id))

        // overlap between new labels and existing clusters → keep ids (and colours) stable across runs
        var overlap: [Int: [ClusterID: Float]] = [:]
        var labelWeight = [Float](repeating: 0, count: result.k)
        for (i, c) in contexts.enumerated() {
            labelWeight[result.labels[i]] += weights[i]
            if let cid = c.clusterID { overlap[result.labels[i], default: [:]][cid, default: 0] += weights[i] }
        }
        var pairs: [(label: Int, cluster: ClusterID, w: Float)] = []
        for (l, m) in overlap { for (cid, w) in m { pairs.append((l, cid, w)) } }
        pairs.sort { $0.w > $1.w }
        var labelToCluster: [Int: ClusterID] = [:]
        var usedClusters = Set<ClusterID>()
        for p in pairs where labelToCluster[p.label] == nil && !usedClusters.contains(p.cluster) {
            guard p.w >= 0.3 * labelWeight[p.label], old.contains(where: { $0.id == p.cluster }) else { continue }
            labelToCluster[p.label] = p.cluster
            usedClusters.insert(p.cluster)
        }
        var usedColors = Set(old.filter { usedClusters.contains($0.id) }.map(\.color))
        for l in 0..<result.k where labelToCluster[l] == nil {
            let color = (0..<ClusterPalette.count).first { !usedColors.contains($0) } ?? (l % ClusterPalette.count)
            usedColors.insert(color)
            let id = try store.insertCluster(ActivityCluster(id: 0, autoName: "סוג פעילות \(l + 1)", color: color), now: Date())
            labelToCluster[l] = id
        }
        // clusters that disappeared (and were not named by the user) are archived — pointing at the new type that
        // absorbed most of their windows, so a focus plan that used the old id keeps working
        for c in old where !usedClusters.contains(c.id) && !userNamedIDs.contains(c.id) {
            let heir = overlap.compactMap { (label, m) in m[c.id].map { (label, $0) } }.max { $0.1 < $1.1 }?.0
            if let heir, let target = labelToCluster[heir] { try store.setClusterMergedInto(c.id, target) }
            try store.setClusterArchived(id: c.id, archived: true)
        }
        var items: [(id: ContextID, cluster: ClusterID?, source: AssignmentSource, confidence: Double)] = []
        for (i, c) in contexts.enumerated() where c.clusterSource != .user {
            let label = result.labels[i]
            let sim = Double(LA.dot(reps[i], result.centroids[label]))
            items.append((c.id, labelToCluster[label], .autoCluster, max(0, sim)))
        }
        try store.setAssignments(items, now: Date())
        Log.info("clustering: \(n) activities → \(result.k) types (silhouette \(String(format: "%.3f", result.silhouette)))", "learning")
    }

    // MARK: - Stage D/E/F (after naming): prototypes, zero-shot LLM, discovery of new types

    private func incrementalAssignment(contexts: [LearningContext], reps: [[Float]], weights: [Float],
                                       llm: ChatLLM?, flag: CancellationFlag) async throws -> [ClusterID] {
        let clusters = try store.clusters()
        guard !clusters.isEmpty else {
            try fullClustering(contexts: contexts, reps: reps, weights: weights)
            return []
        }
        let classIDs = clusters.map(\.id)
        let classIndex = Dictionary(uniqueKeysWithValues: classIDs.enumerated().map { ($1, $0) })
        var memberVecs: [[Float]] = [], memberW: [Float] = [], memberL: [Int] = []
        var pending: [Int] = []
        for (i, c) in contexts.enumerated() {
            if let cid = c.clusterID, let li = classIndex[cid] {
                memberVecs.append(reps[i]); memberW.append(weights[i]); memberL.append(li)
            } else {
                pending.append(i)
            }
        }
        let protos = PrototypeIndex.build(vectors: memberVecs, weights: memberW, labels: memberL, classIDs: classIDs)
        var items: [(id: ContextID, cluster: ClusterID?, source: AssignmentSource, confidence: Double)] = []
        var stillPending: [Int] = []
        for i in pending {
            if let m = protos.bestMatch(reps[i]), !m.isNovel, m.margin >= 0.02 {
                items.append((contexts[i].id, classIDs[m.classIndex], .prototype, Double(m.similarity)))
            } else {
                stillPending.append(i)
            }
        }
        try store.setAssignments(items, now: Date())

        // zero-shot with the local LLM for the heaviest novel activities
        if let llm, !stillPending.isEmpty, !flag.isCancelled {
            update { $0.stage = .naming; $0.detail = "matching new activities" }
            var prepared = true
            do { try await llm.prepare() } catch { prepared = false }
            if prepared {
                let options = clusters.enumerated().map { (i, c) in
                    LLMTasks.TypeOption(number: i + 1, name: c.displayName,
                                        description: c.description ?? (c.keywords.prefix(6) + c.topApps.prefix(3)).joined(separator: ", "))
                }
                var llmItems: [(id: ContextID, cluster: ClusterID?, source: AssignmentSource, confidence: Double)] = []
                var remaining: [Int] = []
                let ordered = stillPending.sorted { contexts[$0].totalSeconds > contexts[$1].totalSeconds }
                for (n, i) in ordered.enumerated() {
                    if flag.isCancelled || n >= 60 { remaining.append(i); continue }
                    if let r = try? await LLMTasks.chooseType(llm, context: contexts[i], options: options),
                       let num = r.number, r.confidence >= 0.5 {
                        llmItems.append((contexts[i].id, clusters[num - 1].id, .llm, r.confidence))
                    } else {
                        remaining.append(i)
                    }
                }
                try store.setAssignments(llmItems, now: Date())
                stillPending = remaining
            }
        }

        // discovery: coherent groups of still-unexplained activity with real time spent → new activity types
        var created: [ClusterID] = []
        if stillPending.count >= 2 {
            let vecs = stillPending.map { reps[$0] }
            let w = stillPending.map { weights[$0] }
            var dist = LA.gram(LA.flatten(vecs), rows: vecs.count, cols: vecs[0].count).map { max(0, 1 - $0) }
            let merges = Agglomerative.linkage(distances: &dist, n: vecs.count, weights: w)
            let labels = Agglomerative.cut(merges, n: vecs.count, threshold: 0.45)
            let k = (labels.max() ?? -1) + 1
            var used = Set(try store.clusters(includeArchived: true).map(\.color))
            for l in 0..<k {
                let members = labels.indices.filter { labels[$0] == l }
                let secs = members.reduce(0.0) { $0 + contexts[stillPending[$1]].totalSeconds }
                guard secs >= 1200, members.count >= 2 || secs >= 2400 else { continue }
                let color = (0..<ClusterPalette.count).first { !used.contains($0) } ?? (l % ClusterPalette.count)
                used.insert(color)
                let id = try store.insertCluster(ActivityCluster(id: 0, autoName: "פעילות חדשה", color: color, isNew: true), now: Date())
                created.append(id)
                try store.setAssignments(members.map { (contexts[stillPending[$0]].id, id, .autoCluster, 0.6) }, now: Date())
            }
            if !created.isEmpty { Log.info("discovered \(created.count) new activity type(s)", "learning") }
        }
        return created
    }

    // MARK: - Stage F: human-readable metadata

    /// Recomputes names/keywords/top apps of all activity types (cheap; no models). Used after merges and splits.
    public func refreshMetadataNow() {
        guard beginRun() != nil else { return } // a running pipeline refreshes metadata itself
        defer { endRun() }
        do { try refreshClusterMetadata() } catch { Log.error("metadata refresh failed: \(error)", "learning") }
    }

    /// Splits one activity type into two by re-clustering its (non-user-assigned) windows. Returns the new type's id.
    /// Returns nil while a learning run is in progress (they share a database connection).
    public func split(cluster id: ClusterID) throws -> ClusterID? {
        guard beginRun() != nil else { return nil }
        defer { endRun() }
        let members = try store.topContexts(cluster: id, limit: 3000).map(\.id)
        let ctxs = try store.learningContexts(ids: members).filter { $0.embedding != nil && $0.clusterSource != .user }
        guard ctxs.count >= 4, let dim = ctxs.first?.embedding?.count else { return nil }
        let usable = ctxs.filter { $0.embedding?.count == dim }
        let inputs = usable.map { c in
            RepresentationInput(textEmbedding: c.embedding!, descriptionEmbedding: c.descriptionEmbedding?.count == dim ? c.descriptionEmbedding : nil,
                                bundleID: c.bundleID, host: c.host, behavior: c.behavior)
        }
        let weights = usable.map { Float(max($0.totalSeconds, 1).squareRoot()) }
        var builder = RepresentationBuilder()
        builder.fit(inputs, weights: weights)
        let reps = inputs.map { builder.represent($0) }
        let n = reps.count
        var dist = LA.gram(LA.flatten(reps), rows: n, cols: reps[0].count).map { max(0, 1 - $0) }
        let labels = Agglomerative.cut(Agglomerative.linkage(distances: &dist, n: n, weights: weights), n: n, k: 2)
        var w = [Float](repeating: 0, count: 2)
        for (i, l) in labels.enumerated() { w[min(l, 1)] += weights[i] }
        guard w[0] > 0, w[1] > 0 else { return nil }
        let minor = w[0] < w[1] ? 0 : 1
        let all = try store.clusters(includeArchived: true)
        let used = Set(all.map(\.color))
        let color = (0..<ClusterPalette.count).first { !used.contains($0) } ?? Int.random(in: 0..<ClusterPalette.count)
        let base = all.first { $0.id == id }
        let newID = try store.insertCluster(ActivityCluster(id: 0, autoName: (base?.autoName ?? "סוג פעילות") + " (2)", color: color),
                                            now: Date())
        let items = labels.indices.filter { labels[$0] == minor }.map { (usable[$0].id, Optional(newID), AssignmentSource.autoCluster, 0.7) }
        try store.setAssignments(items, now: Date())
        try refreshClusterMetadata()
        Log.info("split activity type \(id): \(items.count) windows moved to new type \(newID)", "learning")
        return newID
    }

    private func refreshClusterMetadata() throws {
        try store.refreshClusterTotals()
        let clusters = try store.clusters()
        guard !clusters.isEmpty else { return }
        // keywords from window text, titles, addresses and the LLM's topics (the same evidence the user sees)
        let evidence = ActivityEvidence.build(try store.evidenceRows(minSeconds: Self.minContextSeconds, perGroup: 60,
                                                                     excludingBundleIDs: [AppPaths.ownBundleID]))
        for c in clusters {
            let e = evidence.clusters[c.id]
            var appTime: [String: Double] = [:]
            for w in e?.windows ?? [] {
                let label = ContextNormalizer.isBrowser(w.bundleID) ? (w.host ?? w.appName) : w.appName
                appTime[label, default: 0] += w.seconds
            }
            let top = appTime.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
            let keywords = e?.keywords ?? []
            let kw = keywords.filter { k in !top.contains { $0.lowercased() == k.lowercased() } }
            var name = top.prefix(2).joined(separator: " / ")
            if let first = kw.first { name += name.isEmpty ? first : " · " + first }
            if name.isEmpty { name = c.autoName }
            try store.updateClusterMetadata(id: c.id, autoName: name, keywords: keywords, topApps: top,
                                            totalSeconds: c.totalSeconds, now: Date())
        }
    }

    private func suggestNames(_ llm: ChatLLM, flag: CancellationFlag, language: String) async throws {
        let clusters = try store.clusters().filter { $0.suggestedName == nil && !$0.userNamed }
        guard !clusters.isEmpty else { return }
        update { $0.stage = .naming; $0.detail = "naming \(clusters.count) activity types" }
        guard !flag.isCancelled else { return }
        do { try await llm.prepare() } catch { return }
        for c in clusters {
            if flag.isCancelled { return }
            let top = try store.topContexts(cluster: c.id, limit: 12)
            let full = try store.learningContexts(ids: top.map(\.id))
            let descs = full.compactMap(\.description)
            let brief = LLMTasks.ClusterBrief(windows: top.map { ($0.appName, $0.title, $0.host, $0.seconds / 3600) },
                                              descriptions: Array(Set(descs)).sorted(), keywords: c.keywords)
            if let r = try? await LLMTasks.suggestName(llm, brief: brief, language: language) {
                try store.setClusterSuggestion(id: c.id, suggestedName: r.name, description: r.description.isEmpty ? nil : r.description)
            }
        }
    }

    // MARK: - Stage G: student network

    private func trainStudent(contexts: [LearningContext], classIDs: [Int64], teacherDim: Int,
                              flag: CancellationFlag) throws -> StudentNetwork? {
        guard !classIDs.isEmpty else { return nil }
        let index = Dictionary(uniqueKeysWithValues: classIDs.enumerated().map { ($1, $0) })
        let featurizer = ActivityFeaturizer()
        var samples: [StudentSample] = []
        var classWeight = [Float](repeating: 0, count: classIDs.count)
        for c in contexts {
            let label = c.clusterID.flatMap { index[$0] }
            let timeW = Float(min(1, max(0.1, log1p(c.totalSeconds / 10) / log1p(360))))
            let w = timeW * (c.clusterSource == .user ? 2 : 1)
            let teacher = (c.embedding?.count == teacherDim) ? c.embedding : nil
            guard label != nil || teacher != nil else { continue }
            samples.append(StudentSample(x: featurizer.featurize(c.descriptor), label: label, weight: w, teacher: teacher))
            if let l = label { classWeight[l] += w }
        }
        guard samples.count >= 10 else { return nil }
        // soften class imbalance (√ inverse frequency)
        let meanW = classWeight.filter { $0 > 0 }.reduce(0, +) / Float(max(1, classWeight.filter { $0 > 0 }.count))
        for i in samples.indices {
            if let l = samples[i].label, classWeight[l] > 0 { samples[i].weight *= (meanW / classWeight[l]).squareRoot() }
        }
        var config = StudentConfig()
        config.semanticDim = teacherDim
        config.classCount = classIDs.count
        let net = StudentNetwork(config: config, classIDs: classIDs, seed: 11)
        var opts = StudentTrainingOptions()
        opts.epochs = samples.count < 400 ? 60 : (samples.count < 1500 ? 40 : 25)
        let report = net.train(samples, options: opts, shouldCancel: { flag.isCancelled })
        Log.info("student trained on \(samples.count) samples in \(Int(report.seconds))s, val acc \(report.validationAccuracy.map { String(format: "%.3f", $0) } ?? "-"), cos \(report.validationSemanticCosine.map { String(format: "%.3f", $0) } ?? "-")", "learning")
        return report.cancelled ? nil : net
    }

    /// One graph-convolution step over the co-usage graph: windows the user keeps switching between inside the
    /// same working session (editor ↔ terminal ↔ docs) are pulled towards each other, so an activity type is
    /// learned as a *workflow*, not just as similar-looking text. Rare switches (e.g. into a distraction) barely move.
    private func smoothWithCoUsage(contexts: [LearningContext], reps: [[Float]], beta: Float = 0.4) -> [[Float]] {
        guard let edges = try? store.transitions(since: Date().addingTimeInterval(-30 * 86400)), !edges.isEmpty else { return reps }
        let index = Dictionary(uniqueKeysWithValues: contexts.enumerated().map { ($1.id, $0) })
        var adj = [[(Int, Float)]](repeating: [], count: contexts.count)
        var pairCounts: [Int64: Int] = [:]
        for e in edges {
            guard let i = index[e.a], let j = index[e.b] else { continue }
            let key = Int64(min(i, j)) << 32 | Int64(max(i, j))
            pairCounts[key, default: 0] += e.count
        }
        for (key, n) in pairCounts where n >= 2 {
            let i = Int(key >> 32), j = Int(key & 0xFFFF_FFFF)
            adj[i].append((j, Float(n))); adj[j].append((i, Float(n)))
        }
        return reps.indices.map { i in
            guard !adj[i].isEmpty else { return reps[i] }
            let strength = adj[i].reduce(Float(0)) { $0 + $1.1 }
            var v = reps[i]
            for (j, w) in adj[i] { LA.axpy(&v, reps[j], beta * w / (strength + 3)) }
            return LA.normalized(v)
        }
    }

    private func representationInput(_ c: LearningContext, anchors: [[Float]],
                                     calibration: CategoryAnchors.Calibration?) -> RepresentationInput {
        let desc = (c.descriptionEmbedding?.count == c.embedding?.count) ? c.descriptionEmbedding : nil
        var profile = c.embedding.flatMap { CategoryAnchors.profile($0, anchors: anchors, calibration: calibration) }
        if let d = desc, let pd = CategoryAnchors.profile(d, anchors: anchors, calibration: calibration), var p = profile {
            for k in p.indices { p[k] = 0.5 * (p[k] + pd[k]) } // the abstract description sharpens the kind
            profile = p
        }
        return RepresentationInput(textEmbedding: c.embedding ?? [], descriptionEmbedding: desc, bundleID: c.bundleID,
                                   host: c.host, behavior: c.behavior, categoryProfile: profile)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
