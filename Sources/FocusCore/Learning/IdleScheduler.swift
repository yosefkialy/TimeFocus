import Foundation

/// Starts the learning pipeline only when the Mac is genuinely not in use (no input for N minutes and no video
/// playing), and cancels it — releasing all model memory — within about a second of the user coming back.
public final class IdleScheduler {
    public enum State: Equatable {
        case waiting(reason: String)
        case running
    }

    private let settings: SettingsStore
    private let pipeline: LearningPipeline
    private var timer: Timer?
    private var watcher: DispatchSourceTimer?
    private var task: Task<Void, Never>?
    public private(set) var state: State = .waiting(reason: "")
    public var onStateChange: ((State) -> Void)?
    private let minGapBetweenRuns: TimeInterval = 45 * 60

    public init(settings: SettingsStore, pipeline: LearningPipeline) {
        self.settings = settings
        self.pipeline = pipeline
    }

    public func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = 5
        evaluate()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pipeline.cancel()
    }

    private func setState(_ s: State) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }

    /// Why the pipeline is (not) running now — shown in the UI.
    public func evaluate() {
        if pipeline.isRunning { setState(.running); return }
        let s = settings.current
        let idle = SystemSignals.secondsSinceLastInput()
        let needed = s.learningIdleMinutes * 60
        if idle < needed {
            setState(.waiting(reason: "idle \(Int(idle / 60))/\(Int(needed / 60)) min"))
            return
        }
        if !SystemSignals.pidsPreventingDisplaySleep().isEmpty && idle < 30 * 60 {
            setState(.waiting(reason: "media playing"))
            return
        }
        let power = SystemSignals.power()
        if s.learnOnlyOnPower && !power.onAC { setState(.waiting(reason: "on battery")); return }
        if !power.onAC, let f = power.batteryFraction, f < 0.3 { setState(.waiting(reason: "battery low")); return }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            setState(.waiting(reason: "thermal")); return
        }
        if let last = pipeline.status.lastRun, Date().timeIntervalSince(last) < minGapBetweenRuns {
            setState(.waiting(reason: "recently learned")); return
        }
        launch(.idle)
    }

    /// Manual "learn now" from the UI (not cancelled by user activity).
    public func runNow() {
        guard !pipeline.isRunning else { return }
        launch(.manual)
    }

    private func launch(_ trigger: LearningPipeline.Trigger) {
        setState(.running)
        // the watcher lives on the main queue, like every other access to `watcher`
        let myWatcher: DispatchSourceTimer? = trigger == .idle ? makeWatcher() : nil
        if let myWatcher { watcher = myWatcher }
        let pipeline = self.pipeline
        let finished: () -> Void = { [weak self] in
            guard let self else { return }
            if let myWatcher { self.stopWatcher(myWatcher) } // never another run's watcher
            self.setState(.waiting(reason: "done"))
        }
        task = Task.detached(priority: .utility) {
            await pipeline.run(trigger: trigger)
            DispatchQueue.main.async(execute: finished)
        }
    }

    private func makeWatcher() -> DispatchSourceTimer {
        let w = DispatchSource.makeTimerSource(queue: .main)
        w.schedule(deadline: .now() + 1, repeating: 0.75)
        w.setEventHandler { [weak self, weak w] in
            guard let self, let w else { return }
            if SystemSignals.secondsSinceLastInput() < 2.5 {
                self.pipeline.cancel()
                Log.info("user is back — learning cancelled, models released", "learning")
                self.stopWatcher(w)
            }
        }
        w.resume()
        return w
    }

    private func stopWatcher(_ w: DispatchSourceTimer) {
        w.cancel()
        if let current = watcher, ObjectIdentifier(current as AnyObject) == ObjectIdentifier(w as AnyObject) { watcher = nil }
    }
}
