import AppKit
import FocusCore
import FocusML
import ServiceManagement
import SwiftUI

struct ClusterTime: Identifiable, Equatable {
    var id: String { clusterID.map(String.init) ?? "none" }
    var clusterID: ClusterID?
    var seconds: Double
}

struct TodayStats: Equatable {
    var tracked: Double = 0
    var onTrack: Double = 0
    var offTrack: Double = 0
    var uncertain: Double = 0
    var perCluster: [ClusterTime] = []
    var episodes = 0
    var returned = 0
    var longestDrift: Double = 0
    var focusRatio: Double { onTrack + offTrack > 0 ? onTrack / (onTrack + offTrack) : 0 }
}

enum MainTab: String, CaseIterable, Identifiable {
    case today, timeline, activities, learning, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "היום"
        case .timeline: return "ציר זמן"
        case .activities: return "סוגי פעילות"
        case .learning: return "למידה ומודלים"
        case .settings: return "הגדרות"
        }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .timeline: return "chart.bar.xaxis"
        case .activities: return "square.grid.2x2"
        case .learning: return "brain"
        case .settings: return "gearshape"
        }
    }
}

/// UI-facing state container. All mutations happen on the main thread.
final class AppModel: ObservableObject, FocusEngineDelegate {
    static let shared = AppModel()

    let engine: FocusEngine?
    let startupError: String?
    let notifications = NotificationService()
    private var hotKey: GlobalHotKey?

    @Published var status = LiveStatus()
    @Published var learning = LearningStatus()
    @Published var clusters: [ActivityCluster] = []
    @Published var settings = AppSettings()
    @Published var today = TodayStats()
    @Published var plan = DayPlan(day: Date().dayKey)
    @Published var schedulerState: IdleScheduler.State = .waiting(reason: "")
    @Published var downloads: [String: ModelManager.Progress] = [:]
    @Published var hasAccessibility = Permissions.accessibility
    @Published var hasScreenRecording = Permissions.screenRecording
    @Published var notificationsAuthorized = false
    @Published var selectedTab: MainTab = .today
    @Published var appleIntelligence: (available: Bool, reason: String) = (false, "")
    @Published var llamaBinary: URL?
    @Published var memoryBytes: UInt64 = 0
    /// What the app saw in each activity type (keywords, the LLM's descriptions, windows) — loaded by the activity-types screen.
    @Published var evidence = ActivityEvidenceSnapshot()
    private var evidenceGeneration = 0

    // hooks installed by the AppDelegate (windows / HUD)
    var onNudge: ((NudgeRequest) -> Void)?
    var onQuestion: ((QuestionRequest) -> Void)?
    var onOverlay: ((Double) -> Void)?
    var openMainWindow: ((MainTab?) -> Void)?
    var openOnboarding: (() -> Void)?

    private var statsTimer: Timer?
    private var started = false

    private init() {
        do {
            engine = try FocusEngine()
            startupError = nil
        } catch {
            engine = nil
            startupError = "\(error)"
        }
        if let engine {
            settings = engine.settings.current
            learning = engine.learningStatus
            plan = engine.plan(for: Date().dayKey) ?? DayPlan(day: Date().dayKey)
        }
    }

    // MARK: lifecycle

    func start() {
        guard !started, let engine else { return }
        started = true
        engine.delegate = self
        engine.scheduler.onStateChange = { [weak self] s in DispatchQueue.main.async { self?.schedulerState = s } }
        engine.models.onProgress = { [weak self] p in DispatchQueue.main.async { self?.downloads[p.modelID] = p } }
        notifications.onAction = { [weak self] action, info in self?.handleNotification(action, info) }
        NotificationCenter.default.addObserver(forName: SettingsStore.didChange, object: engine.settings, queue: .main) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            self.settings = engine.settings.current
            self.configureHotKey()
        }
        engine.start()
        configureHotKey()
        reloadClusters()
        refreshStats()
        refreshEnvironment()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshStats()
            self?.refreshEnvironment()
        }
        if NotificationService.canUseNotifications {
            notifications.requestAuthorization { [weak self] ok in DispatchQueue.main.async { self?.notificationsAuthorized = ok } }
        }
    }

    func shutdown() {
        engine?.stop()
    }

    private func configureHotKey() {
        if settings.emergencyHotkeyEnabled {
            if hotKey == nil { hotKey = GlobalHotKey { [weak self] in self?.emergencyStop() } }
        } else {
            hotKey = nil
        }
    }

    func refreshEnvironment() {
        hasAccessibility = Permissions.accessibility
        hasScreenRecording = Permissions.screenRecording
        appleIntelligence = AppleIntelligenceLLM.availability()
        llamaBinary = engine?.models.llamaServerBinary(settingsPath: settings.llamaServerPath)
        memoryBytes = SystemSignals.residentMemoryBytes()
        engine?.pipeline.refreshCounts()
        engine?.scheduler.evaluate()
    }

    func reloadClusters() {
        clusters = (try? engine?.uiStore.clusters()) ?? []
    }

    /// Recomputes the activity-type evidence in the background (tens of milliseconds; the newest request wins).
    func refreshEvidence() {
        guard let engine else { return }
        evidenceGeneration += 1
        let generation = evidenceGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = engine.activityEvidence()
            DispatchQueue.main.async {
                guard let self, generation == self.evidenceGeneration else { return }
                self.evidence = snapshot
            }
        }
    }

    /// Synchronous variant for the snapshot renderer.
    func loadEvidenceNow() {
        if let engine { evidence = engine.activityEvidence() }
    }

    func cluster(_ id: ClusterID?) -> ActivityCluster? {
        guard let id else { return nil }
        return clusters.first { $0.id == id }
    }

    func clusterName(_ id: ClusterID?) -> String {
        cluster(id)?.displayName ?? "לא מסווג"
    }

    func refreshStats() {
        guard let store = engine?.uiStore else { return }
        let start = Date().startOfDay
        let end = start.addingTimeInterval(86400)
        var t = TodayStats()
        let states = (try? store.focusStateSeconds(from: start, to: end)) ?? [:]
        t.onTrack = states[.onTrack] ?? 0
        t.offTrack = states[.offTrack] ?? 0
        t.uncertain = states[.uncertain] ?? 0
        t.tracked = states.values.reduce(0, +)
        let per = (try? store.clusterSeconds(from: start, to: end)) ?? [:]
        t.perCluster = per.map { ClusterTime(clusterID: $0.key, seconds: $0.value) }.filter { $0.seconds >= 30 }.sorted { $0.seconds > $1.seconds }
        let eps = (try? store.episodes(from: start, to: end)) ?? []
        t.episodes = eps.count
        t.returned = eps.filter { $0.outcome == .returned }.count
        t.longestDrift = eps.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
        today = t
        if plan.day != Date().dayKey { plan = engine?.plan(for: Date().dayKey) ?? DayPlan(day: Date().dayKey) }
    }

    // MARK: FocusEngineDelegate

    func engine(_ engine: FocusEngine, didUpdate status: LiveStatus) {
        self.status = status
        maybeMorningPrompt()
    }

    func engine(_ engine: FocusEngine, nudge: NudgeRequest) {
        switch settings.nudgeStyle {
        case .banner: onNudge?(nudge)
        case .notification: postDriftNotification(nudge)
        case .both:
            onNudge?(nudge)
            if !NSApp.isActive || nudge.isRepeat { postDriftNotification(nudge) }
        case .none: break
        }
    }

    func engine(_ engine: FocusEngine, ask: QuestionRequest) { onQuestion?(ask) }

    func engine(_ engine: FocusEngine, learning: LearningStatus) { self.learning = learning }

    func engine(_ engine: FocusEngine, phaseChanged: LearningPhase) {
        learning.phase = phaseChanged
        reloadClusters()
        if phaseChanged == .naming {
            notifications.postInfo(id: "naming", title: "סיימתי ללמוד את ההרגלים שלך 🎉",
                                   body: "זיהיתי \(clusters.count) סוגי פעילות. אפשר לתת להם שמות ולבחור על מה להתמקד היום.")
            selectedTab = .activities
            openMainWindow?(.activities)
        }
    }

    func engine(_ engine: FocusEngine, discoveredClusters: [ClusterID]) {
        reloadClusters()
        notifications.postInfo(id: "new-cluster", title: "זוהה סוג פעילות חדש",
                               body: "נראה שהתחלת משהו חדש. אפשר לתת לו שם במסך \"סוגי פעילות\".")
    }

    func engine(_ engine: FocusEngine, overlayLevel: Double) { onOverlay?(overlayLevel) }

    func engineClustersChanged(_ engine: FocusEngine) { reloadClusters() }

    // MARK: notifications

    private func postDriftNotification(_ n: NudgeRequest) {
        let focus = n.focusNames.isEmpty ? "המיקוד שלך" : n.focusNames.joined(separator: ", ")
        var body = "כרגע: \(n.appName)\(n.title.isEmpty ? "" : " — \(n.title)")"
        if n.throttleLevel > 0 { body += "\nהמחשב מאט את היישום הזה (\(Fmt.percent(n.throttleLevel)))." }
        notifications.postDrift(id: "drift", title: "חזרה אל: \(focus)", body: body,
                                userInfo: ["contextID": NSNumber(value: n.contextID)])
    }

    private func handleNotification(_ action: NotificationService.Action, _ info: [AnyHashable: Any]) {
        let ctx = (info["contextID"] as? NSNumber)?.int64Value
        switch action {
        case .back: backToFocus()
        case .related: if let ctx { allowToday(ctx) }
        case .pause: takeBreak()
        case .open:
            if info["morning"] != nil { openMainWindow?(.today) } else { openMainWindow?(nil) }
        }
    }

    private func maybeMorningPrompt() {
        guard settings.morningPlanPrompt, !status.away, clusters.count >= 2, learning.phase != .collecting,
              plan.blocks.isEmpty, status.focus == nil else { return }
        let today = Date().dayKey
        let key = "morningPrompt.lastDay"
        guard UserDefaults.standard.string(forKey: key) != today, Calendar.current.component(.hour, from: Date()) >= 5 else { return }
        UserDefaults.standard.set(today, forKey: key)
        notifications.postInfo(id: "morning", title: "בוקר טוב ☀️", body: "על מה מתמקדים היום? לחץ כדי לתכנן את היום.")
    }

    // MARK: actions

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        engine?.settings.update(change)
        if let e = engine { settings = e.settings.current }
    }

    func savePlan(_ p: DayPlan) {
        plan = p
        engine?.savePlan(p)
    }

    func copyPlanFromPreviousDay() {
        guard let prev = try? engine?.uiStore.latestPlan(before: Date().dayKey) else { return }
        savePlan(DayPlan(day: Date().dayKey, blocks: prev.blocks.map { FocusBlock(startMinute: $0.startMinute, endMinute: $0.endMinute, clusterIDs: $0.clusterIDs, note: $0.note) }))
    }

    func startFocus(_ ids: [ClusterID], minutes: Double) { engine?.startManualFocus(clusterIDs: ids, minutes: minutes) }
    func endFocus() { engine?.endManualFocus() }
    @discardableResult func takeBreak() -> Bool { engine?.takeBreak() ?? false }
    func endBreak() { engine?.endBreak() }
    func emergencyStop() {
        engine?.emergencyStop()
        onOverlay?(0)
        notifications.postInfo(id: "emergency", title: "ההתערבויות הושהו לשעה", body: "ההאטה בוטלה. אפשר לחדש מתפריט TimeFocus.")
    }
    func resumeInterventions() { engine?.resumeInterventions() }
    func backToFocus() { engine?.backToFocus() }
    func assign(_ ctx: ContextID, to cluster: ClusterID) { engine?.assign(contextID: ctx, to: cluster) }
    func allowToday(_ ctx: ContextID) { engine?.allowToday(contextID: ctx) }
    func markDistraction(_ ctx: ContextID) { engine?.markDistraction(contextID: ctx) }
    func rename(_ id: ClusterID, _ name: String?) { engine?.renameCluster(id, to: name); reloadClusters() }
    func merge(_ source: ClusterID, into target: ClusterID) { engine?.mergeCluster(source, into: target); reloadClusters() }
    func split(_ id: ClusterID) {
        engine?.splitCluster(id) { [weak self] newID in
            self?.reloadClusters()
            if newID == nil {
                self?.notifications.postInfo(id: "split", title: "לא ניתן לפצל אוטומטית",
                                             body: "צריך לפחות 4 חלונות בסוג הפעילות, או שהלמידה רצה כעת. אפשר גם לפצל ידנית: פותחים חלון בכרטיס ובוחרים \"העבר לסוג אחר\".")
            }
        }
    }
    /// Moves a window to another activity type from the activity-types screen (a user label — the strongest signal).
    func move(_ ctx: ContextID, to cluster: ClusterID) {
        engine?.moveContext(ctx, to: cluster)
        reloadClusters()
        refreshEvidence()
    }
    /// Manual split: the window becomes the first member of a new activity type with this name.
    func moveToNewCluster(_ ctx: ContextID, name: String) {
        engine?.moveContextToNewCluster(ctx, name: name)
        reloadClusters()
        refreshEvidence()
    }
    func finishNaming() { engine?.finishNaming(); learning.phase = .active; reloadClusters() }
    func startNamingNow() { engine?.skipToNaming(); learning.phase = .naming }
    func runLearningNow() { engine?.runLearningNow() }
    func setTracking(_ on: Bool) { engine?.setTrackingEnabled(on); settings.trackingEnabled = on }

    func toggleAlwaysAllowed(_ id: ClusterID) {
        updateSettings { s in
            if let i = s.alwaysAllowedClusterIDs.firstIndex(of: id) { s.alwaysAllowedClusterIDs.remove(at: i) }
            else { s.alwaysAllowedClusterIDs.append(id) }
        }
    }

    func download(_ m: CatalogModel) {
        guard let models = engine?.models else { return }
        downloads[m.id] = ModelManager.Progress(modelID: m.id, fraction: 0, bytes: 0, total: m.approxBytes, error: nil, finished: false)
        Task.detached {
            do { try await models.download(m) } catch { Log.error("download failed: \(error)", "models") }
            await MainActor.run { AppModel.shared.refreshEnvironment() }
        }
    }

    func deleteModel(_ m: CatalogModel) {
        engine?.models.delete(m)
        downloads[m.id] = nil
        objectWillChange.send()
    }

    func installLlamaRuntime() {
        guard let models = engine?.models else { return }
        downloads["llama-runtime"] = ModelManager.Progress(modelID: "llama-runtime", fraction: 0, bytes: 0, total: 1, error: nil, finished: false)
        Task.detached {
            do { _ = try await models.installLlamaRuntime() }
            catch {
                await MainActor.run {
                    AppModel.shared.downloads["llama-runtime"] = ModelManager.Progress(modelID: "llama-runtime", fraction: 0, bytes: 0, total: 1,
                                                                                         error: "\(error.localizedDescription)", finished: true)
                }
            }
            await MainActor.run { AppModel.shared.refreshEnvironment() }
        }
    }

    func isInstalled(_ m: CatalogModel) -> Bool { engine?.models.isInstalled(m) ?? false }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateSettings { $0.launchAtLogin = on }
        } catch {
            Log.error("launch at login failed: \(error)")
        }
    }

    func deleteAllData() {
        engine?.deleteAllData()
        reloadClusters()
        refreshStats()
        plan = DayPlan(day: Date().dayKey)
    }

    func excludeCurrentApp() {
        let bid = status.bundleID
        guard !bid.isEmpty else { return }
        updateSettings { s in if !s.excludedBundleIDs.contains(bid) { s.excludedBundleIDs.append(bid) } }
    }
}
