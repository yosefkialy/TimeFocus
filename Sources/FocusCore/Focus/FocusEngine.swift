import AppKit
import Foundation
import FocusML

/// Snapshot of what is happening right now, for the UI (menu bar, dashboard).
public struct LiveStatus: Equatable {
    public var trackingEnabled = true
    public var hasAccessibility = false
    public var away = false
    public var appName = ""
    public var bundleID = ""
    public var title = ""
    public var host: String?
    public var contextID: ContextID?
    public var activityID: ClusterID?
    public var activityName: String?
    public var confidence: Double = 0
    public var novelty: Double = 1
    public var source: Classification.Source = .none
    public var verdict: FocusVerdict = .noPlan
    public var neutralReason: String?
    public var focus: ActiveFocus?
    public var focusNames: [String] = []
    public var throttleLevel: Double = 0
    public var driftSeconds: Double = 0
    public var breakUntil: Date?
    public var breaksLeft = 0
    public var interventionsPausedUntil: Date?
    public var isPrivate = false
    public var updatedAt = Date()
    public init() {}
}

public struct NudgeRequest: Equatable {
    public var contextID: ContextID
    public var appName: String
    public var title: String
    public var activityName: String?
    public var focusNames: [String]
    public var focusClusterIDs: [ClusterID]
    public var driftSeconds: Double
    public var throttleLevel: Double
    public var isRepeat: Bool

    public init(contextID: ContextID, appName: String, title: String, activityName: String?, focusNames: [String],
                focusClusterIDs: [ClusterID], driftSeconds: Double, throttleLevel: Double, isRepeat: Bool) {
        self.contextID = contextID; self.appName = appName; self.title = title; self.activityName = activityName
        self.focusNames = focusNames; self.focusClusterIDs = focusClusterIDs; self.driftSeconds = driftSeconds
        self.throttleLevel = throttleLevel; self.isRepeat = isRepeat
    }
}

public struct QuestionRequest: Equatable {
    public var contextID: ContextID
    public var appName: String
    public var title: String
    public var focusClusterIDs: [ClusterID]
    public var focusNames: [String]
    public var suggestedClusterID: ClusterID?
    public var suggestedName: String?

    public init(contextID: ContextID, appName: String, title: String, focusClusterIDs: [ClusterID], focusNames: [String],
                suggestedClusterID: ClusterID?, suggestedName: String?) {
        self.contextID = contextID; self.appName = appName; self.title = title; self.focusClusterIDs = focusClusterIDs
        self.focusNames = focusNames; self.suggestedClusterID = suggestedClusterID; self.suggestedName = suggestedName
    }
}

/// All callbacks arrive on the main thread.
public protocol FocusEngineDelegate: AnyObject {
    func engine(_ engine: FocusEngine, didUpdate status: LiveStatus)
    func engine(_ engine: FocusEngine, nudge: NudgeRequest)
    func engine(_ engine: FocusEngine, ask: QuestionRequest)
    func engine(_ engine: FocusEngine, learning: LearningStatus)
    func engine(_ engine: FocusEngine, phaseChanged: LearningPhase)
    func engine(_ engine: FocusEngine, discoveredClusters: [ClusterID])
    func engine(_ engine: FocusEngine, overlayLevel: Double)
    func engineClustersChanged(_ engine: FocusEngine)
}

/// Orchestrates tracking → context resolution → classification → focus decision → interventions,
/// and hosts the idle-time learning pipeline.
public final class FocusEngine: ActivityMonitorDelegate {
    public let paths: AppPaths
    public let settings: SettingsStore
    public let monitor: ActivityMonitor
    public let throttler: ProcessThrottler
    public let models: ModelManager
    public let pipeline: LearningPipeline
    public let scheduler: IdleScheduler
    /// Main-thread store for UI reads and user actions.
    public let uiStore: Store
    /// Tracking-queue store.
    private let trackingStore: Store
    private let classifier = RealtimeClassifier()
    private let controller: FocusController
    public weak var delegate: FocusEngineDelegate?

    public private(set) var status = LiveStatus()
    public private(set) var learningStatus = LearningStatus()

    // tracking-queue state
    private struct Current {
        var context: ContextRecord
        var segmentID: Int64
        var classification: Classification
        var verdict: FocusVerdict
        var throttle: Double
        var pid: pid_t
        var started: Date
    }
    private var current: Current?
    private var contextCache: [String: ContextRecord] = [:]
    private var lastText: [ContextID: String] = [:]
    private var planDay = ""
    private var plan: DayPlan?
    private var manualFocus: ActiveFocus?
    private var allowedToday = Set<ContextID>()
    private var denied = Set<ContextID>()
    private var deniedFocusKey = ""
    private var lastOnTrack: (pid: pid_t, title: String)?
    private var episodeID: Int64?
    private var pausedUntil: Date?
    private var clusterNames: [ClusterID: String] = [:]
    /// Merged/re-clustered activity types → the type that replaced them (plans and settings keep old ids).
    private var redirect: [ClusterID: ClusterID] = [:]
    private var watchdogPID: pid_t = 0
    private var started = false
    /// Connection for the activity-type evidence (computed off the main thread, serialised by `evidenceLock`).
    private var evidenceStore: Store?
    private let evidenceLock = NSLock()

    public init(paths: AppPaths = .default, settings: SettingsStore = SettingsStore()) throws {
        self.paths = paths
        self.settings = settings
        uiStore = try Store(url: paths.database)
        trackingStore = try Store(url: paths.database)
        monitor = ActivityMonitor(settings: settings)
        throttler = ProcessThrottler(stateFile: paths.throttleState)
        models = ModelManager(paths: paths)
        pipeline = try LearningPipeline(paths: paths, settings: settings, models: models)
        scheduler = IdleScheduler(settings: settings, pipeline: pipeline)
        controller = FocusController(settings: settings.current)
        learningStatus = pipeline.status
    }

    // MARK: lifecycle

    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        ProcessThrottler.recover(stateFile: paths.throttleState)
        LlamaServerLLM.killLeftover(pidFile: LlamaServerLLM.pidFile(in: paths))
        startWatchdog()
        // no crash watchdog ⇒ no slowdown (and try to bring it back)
        throttler.watchdogAlive = { [weak self] in
            guard let self else { return false }
            if self.watchdogPID > 0, kill(self.watchdogPID, 0) == 0 { return true }
            DispatchQueue.main.async { self.startWatchdog() }
            return false
        }
        monitor.delegate = self
        let throttler = self.throttler
        monitor.isThrottled = { pid in throttler.isThrottling(pid) }
        pipeline.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.learningStatus = s
                self.delegate?.engine(self, learning: s)
            }
        }
        pipeline.onBundle = { [weak self] bundle in self?.install(bundle) }
        pipeline.onPhaseChange = { [weak self] p in
            DispatchQueue.main.async { guard let self else { return }; self.delegate?.engine(self, phaseChanged: p) }
        }
        pipeline.onNewClusters = { [weak self] ids in
            DispatchQueue.main.async { guard let self else { return }; self.delegate?.engine(self, discoveredClusters: ids) }
        }
        NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: settings, queue: .main) { [weak self] _ in
            guard let self else { return }
            let s = self.settings.current
            self.monitor.queue.async { self.controller.settings = s }
        }
        // load the last model bundle
        let bundle = ModelBundle.load(store: uiStore, paths: paths)
        let all = (try? uiStore.clusters(includeArchived: true)) ?? []
        monitor.queue.async { [weak self] in
            guard let self else { return }
            self.applyClusters(all, bundle: bundle)
            if let manual = self.trackingStore.codable("focus.manual", as: ManualFocusRecord.self), manual.end > Date() {
                self.manualFocus = ActiveFocus(clusterIDs: Set(manual.clusterIDs), start: manual.start, end: manual.end,
                                               note: manual.note, isManual: true)
            }
        }
        monitor.start()
        scheduler.start()
        pipeline.refreshCounts()
        Log.info("engine started (accessibility: \(Permissions.accessibility))")
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        scheduler.stop()
        pipeline.cancel() // also kills a running llama-server
        monitor.stop()
        throttler.shutdown()
        monitor.queue.sync { closeCurrent(at: Date()) }
        started = false
    }

    private func startWatchdog() {
        dispatchPrecondition(condition: .onQueue(.main))
        if watchdogPID > 0, kill(watchdogPID, 0) == 0 { return }
        if let pid = ThrottleWatchdog.spawn(stateFile: paths.throttleState, llamaPidFile: LlamaServerLLM.pidFile(in: paths)) {
            watchdogPID = pid
            throttler.protectedPIDs.insert(pid)
        }
    }

    /// Installs clusters (+ optionally a model bundle) — tracking queue only.
    private func applyClusters(_ all: [ActivityCluster], bundle: ModelBundle?) {
        classifier.install(bundle, clusters: all)
        clusterNames = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.displayName) })
        redirect = [:]
        for c in all where c.archived { if let t = c.mergedInto { redirect[c.id] = t } }
    }

    /// Follows merges so focus plans and "always allowed" keep working after activity types are merged.
    private func canonical(_ ids: Set<ClusterID>) -> Set<ClusterID> {
        Set(ids.map { id in
            var id = id
            var hops = 0
            while let next = redirect[id], hops < 8 { id = next; hops += 1 }
            return id
        })
    }

    private func install(_ bundle: ModelBundle) {
        // trackingStore belongs to the tracking queue: read it there, never on the pipeline's thread
        monitor.queue.async { [weak self] in
            guard let self else { return }
            let all = (try? self.trackingStore.clusters(includeArchived: true)) ?? []
            self.applyClusters(all, bundle: bundle)
            self.contextCache.removeAll() // assignments changed
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engineClustersChanged(self)
        }
    }

    /// Re-reads clusters after a user edit (rename/merge) without rebuilding models.
    public func reloadClusters() {
        let all = (try? uiStore.clusters(includeArchived: true)) ?? []
        let bundle = ModelBundle.load(store: uiStore, paths: paths)
        monitor.queue.async { [weak self] in
            guard let self else { return }
            self.applyClusters(all, bundle: bundle)
            self.contextCache.removeAll()
        }
        delegate?.engineClustersChanged(self)
    }

    // MARK: ActivityMonitorDelegate (tracking queue)

    public func monitor(_ monitor: ActivityMonitor, didRecognizeText text: String, forKey key: String) {
        // OCR is asynchronous: only keep the text if the user is still on the window it was captured from
        guard current?.context.key == key, let ctx = contextCache[key], !ctx.isPrivate else { return }
        try? trackingStore.mergeContextText(id: ctx.id, text: text, now: Date())
        lastText[ctx.id] = String(((lastText[ctx.id] ?? "") + "\n" + text).prefix(3000))
    }

    public func monitor(_ monitor: ActivityMonitor, didCapture snap: ActivitySnapshot) {
        let s = settings.current
        let now = snap.time
        rollDay(now)

        // tracking paused while this capture was in flight: fail open (release everything) and stop
        guard s.trackingEnabled else {
            closeCurrent(at: now)
            applyInterventions(pid: snap.pid, bundleID: snap.bundleID, output: nil, paused: true)
            return
        }

        // 1) attribute the elapsed interval to the activity that was on screen
        let away = snap.locked || (snap.secondsSinceInput >= s.awayAfterSeconds && !snap.mediaPlaying)
        if var cur = current {
            let idleOverflow = max(0, snap.secondsSinceInput - s.awayAfterSeconds)
            let active = snap.mediaPlaying ? snap.interval : max(0, snap.interval - idleOverflow)
            let media = snap.mediaPlaying ? snap.interval : 0
            do {
                try trackingStore.extendSegment(id: cur.segmentID, end: now, activeSeconds: active, keys: snap.input.keys,
                                                clicks: snap.input.clicks, scrolls: snap.input.scrolls, moves: snap.input.moves,
                                                mediaSeconds: media, clusterID: cur.classification.clusterID,
                                                confidence: cur.classification.confidence, focusState: cur.verdict.stateCode,
                                                throttle: cur.throttle)
                if active > 0 {
                    try trackingStore.addContextActivity(id: cur.context.id, seconds: active, keys: snap.input.keys,
                                                         clicks: snap.input.clicks, scrolls: snap.input.scrolls,
                                                         moves: snap.input.moves, mediaSeconds: media, at: now)
                    cur.context.totalSeconds += active
                    cur.context.behavior.seconds += active
                    cur.context.behavior.keys += snap.input.keys
                    cur.context.behavior.clicks += snap.input.clicks
                    cur.context.behavior.scrolls += snap.input.scrolls
                    cur.context.behavior.moves += snap.input.moves
                    cur.context.behavior.mediaSeconds += media
                    contextCache[cur.context.key] = cur.context
                    current = cur
                }
            } catch {
                Log.error("segment update failed: \(error)", "tracking")
            }
        }

        // 2) away / locked → close the segment, pause the drift clock, release everything
        if away {
            closeCurrent(at: now)
            controller.noteAway()
            applyInterventions(pid: snap.pid, bundleID: snap.bundleID, output: nil, paused: true)
            let focus = activeFocus(now)
            let focusNames = names(focus?.clusterIDs)
            let reason = snap.locked ? "locked" : "away"
            publish { st in
                st.away = true
                st.verdict = focus == nil ? .noPlan : .neutral
                st.neutralReason = reason
                st.throttleLevel = 0
                st.focus = focus
                st.focusNames = focusNames
            }
            return
        }

        // 3) resolve the context (on failure: fail open — never leave a previous target slowed down)
        guard var ctx = resolveContext(snap) else {
            applyInterventions(pid: snap.pid, bundleID: snap.bundleID, output: nil, paused: true)
            return
        }
        if let t = snap.text, !t.isEmpty, !snap.isPrivate {
            try? trackingStore.mergeContextText(id: ctx.id, text: t, now: now)
            lastText[ctx.id] = String((t + "\n" + (lastText[ctx.id] ?? "")).prefix(3000))
            ctx.textUpdatedAt = now
        }
        if lastText.count > 3000 { lastText.removeAll() }

        // 4) classify
        let classification = snap.isPrivate || snap.isOwnApp ? .none : classifier.classify(context: ctx, text: lastText[ctx.id], now: now)

        // 5) focus decision
        let focus = activeFocus(now)
        let focusKey = focus.map { "\($0.start.timeIntervalSince1970)-\($0.clusterIDs.sorted())" } ?? ""
        if focusKey != deniedFocusKey { denied.removeAll(); deniedFocusKey = focusKey }
        let input = FocusInput(now: now, focus: focus, classification: classification, contextID: ctx.id,
                               isPrivate: snap.isPrivate, isOwnApp: snap.isOwnApp, contextAllowed: allowedToday.contains(ctx.id),
                               contextDenied: denied.contains(ctx.id), alwaysAllowed: canonical(Set(s.alwaysAllowedClusterIDs)))
        let out = controller.evaluate(input)
        let paused = (pausedUntil.map { $0 > now } ?? false)
        if out.verdict == .onTrack { lastOnTrack = (snap.pid, snap.title) }
        handleEpisode(out, ctx: ctx, classification: classification, now: now)

        // 6) segment bookkeeping (a new segment per context switch, and at most 10 minutes long)
        let switched = current?.context.id != ctx.id || current.map { now.timeIntervalSince($0.started) > 600 } ?? true
        if switched {
            closeCurrent(at: now)
            if let segID = try? trackingStore.insertSegment(contextID: ctx.id, start: now, clusterID: classification.clusterID,
                                                              confidence: classification.confidence, focusState: out.verdict.stateCode) {
                current = Current(context: ctx, segmentID: segID, classification: classification, verdict: out.verdict,
                                  throttle: out.throttleLevel, pid: snap.pid, started: now)
            }
        } else if var cur = current {
            cur.context = ctx
            cur.classification = classification
            cur.verdict = out.verdict
            cur.throttle = out.throttleLevel
            cur.pid = snap.pid
            current = cur
        }

        // 7) interventions — every value handed to the main thread is computed here, on the tracking queue
        applyInterventions(pid: snap.pid, bundleID: snap.bundleID, output: out, paused: paused)
        let activityName = classification.clusterID.flatMap { clusterNames[$0] }
        let focusNames = names(focus?.clusterIDs)
        if out.nudge && !paused {
            let req = NudgeRequest(contextID: ctx.id, appName: snap.appName, title: snap.title, activityName: activityName,
                                   focusNames: focusNames, focusClusterIDs: Array(focus?.clusterIDs ?? []),
                                   driftSeconds: out.driftSeconds, throttleLevel: out.throttleLevel, isRepeat: out.isRepeatNudge)
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.delegate?.engine(self, nudge: req) }
        }
        if out.ask && !paused, let f = focus {
            let q = QuestionRequest(contextID: ctx.id, appName: snap.appName, title: snap.title, focusClusterIDs: Array(f.clusterIDs),
                                    focusNames: focusNames, suggestedClusterID: classification.clusterID, suggestedName: activityName)
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.delegate?.engine(self, ask: q) }
        }

        // 8) publish (the closure only captures values)
        let breaksLeft = controller.breaksLeft
        let breakUntil = controller.breakUntil
        let pausedUntil = self.pausedUntil
        let ctxID = ctx.id
        publish { st in
            st.away = false
            st.appName = snap.appName
            st.bundleID = snap.bundleID
            st.title = snap.isPrivate ? "" : snap.title
            st.host = snap.host
            st.isPrivate = snap.isPrivate
            st.contextID = ctxID
            st.activityID = classification.clusterID
            st.activityName = activityName
            st.confidence = classification.confidence
            st.novelty = classification.novelty
            st.source = classification.source
            st.verdict = out.verdict
            st.neutralReason = paused && out.verdict == .offTrack ? "paused" : out.neutralReason
            st.focus = focus
            st.focusNames = focusNames
            st.throttleLevel = paused ? 0 : out.throttleLevel
            st.driftSeconds = out.driftSeconds
            st.breakUntil = breakUntil
            st.breaksLeft = breaksLeft
            st.interventionsPausedUntil = pausedUntil
        }
    }

    // MARK: helpers (tracking queue)

    private func rollDay(_ now: Date) {
        let d = now.dayKey
        guard d != planDay else { return }
        planDay = d
        plan = try? trackingStore.plan(day: d)
        allowedToday = (try? trackingStore.allowedContexts(since: now.startOfDay)) ?? []
    }

    private func resolveContext(_ snap: ActivitySnapshot) -> ContextRecord? {
        if var c = contextCache[snap.key] {
            if snap.reason != .tick || Date().timeIntervalSince(c.textUpdatedAt ?? .distantPast) > 60 {
                try? trackingStore.touchContext(id: c.id, urlPath: snap.urlPath, now: snap.time)
            }
            c.urlPath = snap.urlPath ?? c.urlPath
            return c
        }
        do {
            let c = try trackingStore.context(key: snap.key)
                ?? trackingStore.insertContext(key: snap.key, bundleID: snap.bundleID, appName: snap.appName, title: snap.title,
                                               host: snap.host, urlPath: snap.urlPath, docPath: snap.documentPath,
                                               isPrivate: snap.isPrivate || snap.isOwnApp, now: snap.time)
            if contextCache.count > 2000 { contextCache.removeAll() }
            contextCache[snap.key] = c
            return c
        } catch {
            Log.error("context resolve failed: \(error)", "tracking")
            return nil
        }
    }

    private func closeCurrent(at date: Date) {
        current = nil
    }

    private func activeFocus(_ now: Date) -> ActiveFocus? {
        if let m = manualFocus {
            if m.end > now {
                var f = m
                f.clusterIDs = canonical(m.clusterIDs)
                return f
            }
            manualFocus = nil
            try? trackingStore.setData("focus.manual", nil)
        }
        guard let plan, let block = plan.block(at: now) else { return nil }
        let start = now.startOfDay.addingTimeInterval(Double(block.startMinute) * 60)
        let end = now.startOfDay.addingTimeInterval(Double(block.endMinute) * 60)
        return ActiveFocus(clusterIDs: canonical(Set(block.clusterIDs)), start: start, end: end, note: block.note,
                           isManual: false, blockID: block.id)
    }

    private func names(_ ids: Set<ClusterID>?) -> [String] {
        (ids ?? []).sorted().compactMap { clusterNames[$0] }
    }

    private func applyInterventions(pid: pid_t, bundleID: String, output: FocusOutput?, paused: Bool) {
        let s = settings.current
        var level = 0.0
        if let o = output, o.verdict == .offTrack, !paused, s.throttlingEnabled, s.trackingEnabled,
           !s.neverThrottleBundleIDs.contains(bundleID) {
            level = o.throttleLevel
        }
        throttler.set(target: pid, bundleID: bundleID, level: level)
        let overlay = s.dimOverlayEnabled ? level : 0
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.delegate?.engine(self, overlayLevel: overlay) }
    }

    private func handleEpisode(_ out: FocusOutput, ctx: ContextRecord, classification: Classification, now: Date) {
        if out.episodeStarted {
            episodeID = try? trackingStore.insertEpisode(start: now, contextID: ctx.id, clusterID: classification.clusterID)
        }
        if let id = episodeID {
            if let outcome = out.episodeEnded {
                let summary = out.endedEpisode // captured before the controller reset its counters
                try? trackingStore.updateEpisode(id: id, end: summary?.lastOffTrack ?? now, maxLevel: summary?.maxLevel ?? 0,
                                                 nudges: summary?.nudges ?? 0, outcome: outcome)
                episodeID = nil
            } else if out.verdict == .offTrack {
                try? trackingStore.updateEpisode(id: id, end: now, maxLevel: out.throttleLevel,
                                                 nudges: controller.nudgesThisEpisode, outcome: .ongoing)
            }
        }
    }

    /// Closes the open drift episode (if any) with an explicit outcome and resets the controller — used by every
    /// user action that ends a drift from outside the state machine. Tracking queue only.
    private func closeOpenEpisode(_ outcome: EpisodeOutcome, now: Date = Date()) {
        if let id = episodeID, controller.hasOpenEpisode {
            let summary = controller.episodeSummary
            try? trackingStore.updateEpisode(id: id, end: summary.lastOffTrack ?? now, maxLevel: summary.maxLevel,
                                             nudges: summary.nudges, outcome: outcome)
        }
        episodeID = nil
        controller.reset()
    }

    private func publish(_ change: @escaping (inout LiveStatus) -> Void) {
        let tracking = settings.current.trackingEnabled
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var st = self.status
            change(&st)
            st.trackingEnabled = tracking
            st.hasAccessibility = Permissions.accessibility
            st.updatedAt = Date()
            self.status = st
            self.delegate?.engine(self, didUpdate: st)
        }
    }

    // MARK: user actions (main thread)

    struct ManualFocusRecord: Codable { var clusterIDs: [ClusterID]; var start: Date; var end: Date; var note: String }

    public func savePlan(_ plan: DayPlan) {
        try? uiStore.savePlan(plan)
        monitor.queue.async { [weak self] in
            guard let self else { return }
            if plan.day == self.planDay { self.plan = plan }
        }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    public func plan(for day: String) -> DayPlan? { try? uiStore.plan(day: day) }

    public func startManualFocus(clusterIDs: [ClusterID], minutes: Double, note: String = "") {
        let now = Date()
        let rec = ManualFocusRecord(clusterIDs: clusterIDs, start: now, end: now.addingTimeInterval(minutes * 60), note: note)
        try? uiStore.setCodable("focus.manual", rec)
        monitor.queue.async { [weak self] in
            self?.closeOpenEpisode(.blockEnded)
            self?.manualFocus = ActiveFocus(clusterIDs: Set(clusterIDs), start: rec.start, end: rec.end, note: note, isManual: true)
        }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    public func endManualFocus() {
        try? uiStore.setData("focus.manual", nil)
        monitor.queue.async { [weak self] in self?.manualFocus = nil }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    @discardableResult
    public func takeBreak(minutes: Double? = nil) -> Bool {
        // decided from the published status so the main thread never waits on the tracking queue
        guard status.breaksLeft > 0 || status.focus == nil else { return false }
        throttler.releaseAll()
        monitor.queue.async { [weak self] in self?.controller.startBreak(now: Date(), minutes: minutes) }
        monitor.captureSoon(.manual, delay: 0.1)
        return true
    }

    public func endBreak() {
        monitor.queue.async { [weak self] in self?.controller.endBreak() }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    /// Emergency stop (menu or ⌃⌥⌘.): releases the slowdown and pauses interventions for an hour.
    public func emergencyStop() {
        throttler.releaseAll()
        let until = Date().addingTimeInterval(3600)
        monitor.queue.async { [weak self] in
            guard let self else { return }
            self.pausedUntil = until
            self.closeOpenEpisode(.dismissed)
            self.throttler.releaseAll() // after any capture that was already in flight
        }
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.delegate?.engine(self, overlayLevel: 0) }
        Log.info("emergency stop: interventions paused for 1h", "intervention")
        monitor.captureSoon(.manual, delay: 0.1)
    }

    public func resumeInterventions() {
        monitor.queue.async { [weak self] in self?.pausedUntil = nil }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    /// "Back to focus": brings the last on-track window to the front.
    public func backToFocus() {
        monitor.queue.async { [weak self] in
            guard let target = self?.lastOnTrack else { return }
            ActivityMonitor.bringToFront(pid: target.pid, windowTitle: target.title)
        }
    }

    /// The user says the current window belongs to an activity type (strongest training signal).
    public func assign(contextID: ContextID, to clusterID: ClusterID) {
        try? uiStore.setAssignments([(contextID, clusterID, .user, 1.0)], now: Date())
        try? uiStore.addFeedback(contextID: contextID, clusterID: clusterID, kind: .assign)
        monitor.queue.async { [weak self] in
            guard let self else { return }
            for (k, v) in self.contextCache where v.id == contextID {
                var c = v
                c.clusterID = clusterID
                c.clusterSource = .user
                c.clusterConfidence = 1
                self.contextCache[k] = c
            }
            self.denied.remove(contextID)
            if self.current?.context.id == contextID { self.closeOpenEpisode(.markedRelevant) }
        }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    /// "It's related to my focus" without choosing a type: allowed for the rest of today.
    public func allowToday(contextID: ContextID) {
        try? uiStore.addFeedback(contextID: contextID, clusterID: nil, kind: .allowDuringFocus)
        monitor.queue.async { [weak self] in
            guard let self else { return }
            self.allowedToday.insert(contextID)
            self.denied.remove(contextID)
            self.closeOpenEpisode(.markedRelevant)
            self.throttler.releaseAll()
        }
        throttler.releaseAll()
        monitor.captureSoon(.manual, delay: 0.1)
    }

    /// "This is a distraction" (answer to an uncertainty question) — counts as off-track for the current focus.
    public func markDistraction(contextID: ContextID) {
        monitor.queue.async { [weak self] in self?.denied.insert(contextID) }
        monitor.captureSoon(.manual, delay: 0.1)
    }

    public func renameCluster(_ id: ClusterID, to name: String?) {
        try? uiStore.renameCluster(id: id, name: name)
        reloadClusters()
    }

    public func mergeCluster(_ source: ClusterID, into target: ClusterID) {
        try? uiStore.mergeCluster(source, into: target)
        reloadClusters()
        let pipeline = self.pipeline
        DispatchQueue.global(qos: .utility).async { [weak self] in
            pipeline.refreshMetadataNow() // keywords / top apps of the merged type
            DispatchQueue.main.async { self?.reloadClusters() }
        }
    }

    /// What the app saw in every activity type — keywords from window text, titles and addresses, the LLM's
    /// descriptions, per-window details. Reads with its own connection: call it off the main thread (tens of ms).
    public func activityEvidence() -> ActivityEvidenceSnapshot {
        evidenceLock.lock(); defer { evidenceLock.unlock() }
        if evidenceStore == nil { evidenceStore = try? Store(url: paths.database) }
        guard let rows = try? evidenceStore?.evidenceRows(minSeconds: 10, perGroup: 60, excludingBundleIDs: [AppPaths.ownBundleID])
        else { return ActivityEvidenceSnapshot() }
        return ActivityEvidence.build(rows)
    }

    /// The user moves a window to another activity type from the activity-types screen.
    public func moveContext(_ contextID: ContextID, to clusterID: ClusterID) {
        assign(contextID: contextID, to: clusterID)
        try? uiStore.refreshClusterTotals()
        reloadClusters()
    }

    /// Manual split: moves a window to a new activity type with the name the user gave it. Returns the new type's id.
    @discardableResult
    public func moveContextToNewCluster(_ contextID: ContextID, name: String) -> ClusterID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let all = (try? uiStore.clusters(includeArchived: true)) ?? []
        let used = Set(all.filter { !$0.archived }.map(\.color))
        let color = (0..<ClusterPalette.count).first { !used.contains($0) } ?? all.count % ClusterPalette.count
        // named by the user, so re-clustering during the learning phase keeps it
        guard let id = try? uiStore.insertCluster(ActivityCluster(id: 0, name: trimmed, autoName: trimmed, color: color, userNamed: true),
                                                  now: Date()) else { return nil }
        moveContext(contextID, to: id)
        Log.info("window moved to new activity type \(id)")
        return id
    }

    /// Splits an activity type in two (background work; the models retrain at the next learning run).
    public func splitCluster(_ id: ClusterID, completion: @escaping (ClusterID?) -> Void) {
        let pipeline = self.pipeline
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? pipeline.split(cluster: id)
            DispatchQueue.main.async {
                self?.reloadClusters()
                completion(result)
            }
        }
    }

    public func finishNaming() {
        pipeline.setPhase(.active)
        for c in (try? uiStore.clusters()) ?? [] where c.isNew { try? uiStore.setClusterNew(id: c.id, isNew: false) }
        reloadClusters()
    }

    public func skipToNaming() { pipeline.setPhase(.naming) }

    public func runLearningNow() { scheduler.runNow() }

    public func setTrackingEnabled(_ on: Bool) {
        settings.update { $0.trackingEnabled = on }
        if !on {
            throttler.releaseAll()
            // queued behind any capture already in flight, so nothing can re-arm the slowdown afterwards
            monitor.queue.async { [weak self] in
                guard let self else { return }
                self.closeCurrent(at: Date())
                self.closeOpenEpisode(.dismissed)
                self.throttler.releaseAll()
                DispatchQueue.main.async { self.delegate?.engine(self, overlayLevel: 0) }
            }
            publish { $0.verdict = .noPlan; $0.throttleLevel = 0 }
        }
    }

    /// Deletes everything that was learned and tracked. Stops (and waits for) a running learning pass first so it
    /// cannot write results back, and resets every piece of in-memory state that referred to the old data.
    public func deleteAllData() {
        dispatchPrecondition(condition: .onQueue(.main))
        throttler.releaseAll()
        scheduler.stop()
        pipeline.cancel()
        let deadline = Date().addingTimeInterval(20)
        while pipeline.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        monitor.queue.sync {
            closeOpenEpisode(.dismissed)
            current = nil
            contextCache.removeAll()
            lastText.removeAll()
            plan = nil
            planDay = ""
            manualFocus = nil
            allowedToday = []
            denied = []
            pausedUntil = nil
            lastOnTrack = nil
            try? trackingStore.deleteAllData()
            applyClusters([], bundle: nil)
        }
        try? FileManager.default.removeItem(at: paths.studentModel)
        settings.update { $0.alwaysAllowedClusterIDs = [] }
        pipeline.setPhase(.collecting)
        pipeline.refreshCounts()
        scheduler.start()
        delegate?.engineClustersChanged(self)
    }
}
