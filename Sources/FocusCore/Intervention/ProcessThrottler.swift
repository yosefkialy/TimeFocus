import Darwin
import Foundation

/// Gradually slows down ONE target app (and its helper processes) by rapidly pausing and resuming it
/// (SIGSTOP/SIGCONT duty cycle) and demoting it to background CPU/IO priority. At level 0.1 the app stutters
/// slightly; around 0.5 it feels sluggish; at 0.85 it is barely usable. Everything is released instantly when
/// the level returns to 0, when the target changes, on quit, and — via the separate watchdog process — even when
/// TimeFocus crashes or is killed.
///
/// Safety rules:
///  • only processes of the current user; never TimeFocus, its watchdog, or critical system processes;
///  • a process that is already stopped by someone else (e.g. a Ctrl-Z'd job) is left alone — we only resume
///    what we ourselves paused in the same cycle;
///  • no throttling at all unless the watchdog is alive.
public final class ProcessThrottler {
    public private(set) var level: Double = 0
    private var targetRoot: pid_t = 0
    private var targetBundleID = ""
    private var pids: [pid_t] = []
    private var demoted = Set<pid_t>()
    /// Start times of current targets (pid + start time identify a process even if pids get recycled).
    private var startTimes: [pid_t: UInt64] = [:]
    /// Processes we pause every cycle (what the watchdog must resume if we die mid-pause). Written to the state
    /// file only when it changes.
    private var pauseSet = Set<pid_t>()
    /// Processes currently paused by us at this very moment (between SIGSTOP and SIGCONT).
    private var pausedNow: [pid_t] = []
    private var lastRefresh = Date.distantPast
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    private var isShutDown = false
    private let statePath: URL
    private let ownPID = getpid()
    public var protectedPIDs = Set<pid_t>()
    /// Returns whether the crash watchdog is alive (and may try to restart it). No watchdog ⇒ no throttling.
    public var watchdogAlive: (() -> Bool)?

    /// Processes that must never be paused, whatever the classification says.
    static let criticalNames: Set<String> = [
        "WindowServer", "loginwindow", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter", "launchd",
        "kernel_task", "coreaudiod", "Finder", "universalaccessd", "TextInputMenuAgent", "Spotlight", "logind",
        "tf-watchdog",
    ]

    public init(stateFile: URL) {
        statePath = stateFile
    }

    // MARK: control

    /// Sets the throttle target and level (0…1). A different target releases the previous one immediately.
    public func set(target pid: pid_t, bundleID: String, level newLevel: Double) {
        var lvl = max(0, min(1, newLevel))
        lock.lock()
        if isShutDown { lvl = 0 }
        let targetChanged = pid != targetRoot
        if targetChanged || lvl <= 0 {
            // no SIGCONT here: the duty-cycle thread always resumes, within the same cycle (≤ 0.24 s), exactly what it
            // paused — and must never resume a process that somebody else stopped
            let oldDemoted = demoted
            pids = []
            demoted = []
            lock.unlock()
            Self.restorePriority(oldDemoted)
            lock.lock()
        }
        targetRoot = lvl > 0 ? pid : 0
        targetBundleID = bundleID
        level = lvl
        if lvl > 0 && (targetChanged || pids.isEmpty) { lastRefresh = .distantPast }
        let needThread = lvl > 0 && !running
        lock.unlock()
        if needThread { startThread() }
    }

    public func releaseAll() {
        set(target: 0, bundleID: "", level: 0)
    }

    /// Whether `pid` is the app currently being slowed down.
    public func isThrottling(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return level > 0 && targetRoot == pid
    }

    /// Call on app termination: releases everything, refuses new targets, and waits for the duty-cycle thread to
    /// finish its current cycle (it resumes what it paused); resumes directly only as a last resort.
    public func shutdown() {
        lock.lock(); isShutDown = true; lock.unlock()
        releaseAll()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            lock.lock(); let busy = running; lock.unlock()
            if !busy { break }
            usleep(20_000)
        }
        lock.lock(); let stuck = pausedNow; let dem = demoted; lock.unlock()
        Self.resumeIfStopped(stuck)
        Self.restorePriority(dem)
        writeState([], demoted: [])
    }

    // MARK: duty-cycle thread

    private func startThread() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let t = Thread { [weak self] in self?.loop() }
        t.name = "timefocus.throttle"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func loop() {
        var rng = SystemRandomNumberGenerator()
        while true {
            lock.lock()
            let lvl = level
            let root = targetRoot
            if lvl <= 0 || root == 0 {
                running = false
                lock.unlock()
                return
            }
            if Date().timeIntervalSince(lastRefresh) > 3 {
                lock.unlock()
                let guardOK = watchdogAlive?() ?? true
                let fresh = guardOK ? computeTargets(root: root) : []
                if !guardOK { Log.error("throttle watchdog not running — slowdown suspended", "intervention") }
                let starts = Dictionary(fresh.compactMap { p in ProcessTree.bsd(p).map { (p, $0.start) } }, uniquingKeysWith: { a, _ in a })
                lock.lock()
                if targetRoot == root {
                    pids = fresh
                    startTimes = starts
                    lastRefresh = Date()
                    // demote to background QoS (E-cores + IO throttling) once the slowdown is noticeable
                    if level >= 0.25 {
                        for p in fresh where !demoted.contains(p) {
                            if setpriority(PRIO_DARWIN_PROCESS, UInt32(p), PRIO_DARWIN_BG) == 0 { demoted.insert(p) }
                        }
                    }
                }
            }
            let targets = pids
            lock.unlock()

            let period = 0.25
            let jitter = Double.random(in: 0.8...1.2, using: &rng)
            let stopFor = min(period * 0.95, period * lvl * jitter)
            if stopFor > 0.002, !targets.isEmpty {
                // never take over a process that somebody else has stopped (e.g. a suspended shell job)
                let mine = targets.filter { !(ProcessTree.bsd($0)?.stopped ?? true) }
                lock.lock()
                pausedNow = mine
                let changed = Set(mine) != pauseSet
                if changed { pauseSet = Set(mine) }
                let starts = startTimes, dem = demoted
                lock.unlock()
                if changed { writeState(mine.compactMap { p in starts[p].map { (p, $0) } }, demoted: dem.compactMap { p in starts[p].map { (p, $0) } }) }
                for p in mine { kill(p, SIGSTOP) }
                usleep(useconds_t(stopFor * 1_000_000))
                for p in mine { kill(p, SIGCONT) }
                lock.lock(); pausedNow = []; lock.unlock()
            }
            usleep(useconds_t(max(0.01, period - stopFor) * 1_000_000))
        }
    }

    private func computeTargets(root: pid_t) -> [pid_t] {
        let procs = ProcessTree.allProcesses()
        let uid = getuid()
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var set = ProcessTree.descendants(of: root, in: procs)
        if targetBundleID == "com.apple.Safari" {
            // Safari renders pages in XPC helpers owned by launchd.
            set += procs.filter { $0.name.hasPrefix("com.apple.WebKit.WebContent") }.map(\.pid)
        }
        return set.filter { p in
            guard p > 1, p != ownPID, !protectedPIDs.contains(p), let info = byPID[p], info.uid == uid else { return false }
            return !Self.criticalNames.contains(info.name)
        }
    }

    /// SIGCONT only processes that are actually stopped (a process somebody else stopped is not in our lists).
    static func resumeIfStopped(_ pids: [pid_t]) {
        for p in pids where ProcessTree.bsd(p)?.stopped == true { kill(p, SIGCONT) }
    }

    static func restorePriority(_ pids: Set<pid_t>) {
        for p in pids { setpriority(PRIO_DARWIN_PROCESS, UInt32(p), 0) }
    }

    // MARK: crash safety

    /// State for the watchdog: processes we pause each cycle, and processes we demoted (both with start times).
    private func writeState(_ procs: [(pid_t, UInt64)], demoted: [(pid_t, UInt64)]) {
        let obj: [String: Any] = [
            "procs": procs.map { ["pid": Int($0.0), "start": NSNumber(value: $0.1)] },
            "demoted": demoted.map { ["pid": Int($0.0), "start": NSNumber(value: $0.1)] },
            "updated": Date().timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: statePath, options: .atomic) }
    }

    /// Resumes whatever a previous run may have left paused (called at launch). Uses the process start time so a
    /// recycled pid belonging to an unrelated process is never touched.
    public static func recover(stateFile: URL) {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func entries(_ key: String) -> [(pid_t, UInt64?)] {
            if let procs = obj[key] as? [[String: Any]] {
                return procs.compactMap { p in (p["pid"] as? Int).map { (pid_t($0), (p["start"] as? NSNumber)?.uint64Value) } }
            }
            if key == "procs", let list = obj["pids"] as? [Int] { return list.map { (pid_t($0), nil) } } // old format
            return []
        }
        func alive(_ pid: pid_t, _ start: UInt64?) -> (start: UInt64, stopped: Bool, uid: uid_t)? {
            guard pid > 1, let info = ProcessTree.bsd(pid) else { return nil }
            if let start, info.start != start { return nil } // pid recycled by an unrelated process
            return info
        }
        for (pid, start) in entries("procs") { if let info = alive(pid, start), info.stopped { kill(pid, SIGCONT) } }
        for (pid, start) in entries("demoted") where alive(pid, start) != nil { setpriority(PRIO_DARWIN_PROCESS, UInt32(pid), 0) }
        try? JSONSerialization.data(withJSONObject: ["procs": [], "demoted": [], "updated": Date().timeIntervalSince1970])
            .write(to: stateFile, options: .atomic)
    }
}

/// The crash watchdog: a tiny separate executable (`tf-watchdog`, a different process name so `killall TimeFocus`
/// cannot take it down too) that waits for the app to exit for any reason, then resumes every process the app may
/// have left paused and stops a llama-server the app may have left running.
public enum ThrottleWatchdog {
    /// Legacy/self-exec mode (used when the helper binary is missing): `TimeFocus --throttle-watchdog <pid> <state> [<llama pid file>]`.
    public static let flag = "--throttle-watchdog"
    public static let helperName = "tf-watchdog"

    /// Entry point for the legacy self-exec mode. Never returns when the flag is present.
    public static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), args.count > i + 2, let parent = pid_t(args[i + 1]) else { return }
        let state = URL(fileURLWithPath: args[i + 2])
        let llamaPidFile = args.count > i + 3 ? URL(fileURLWithPath: args[i + 3]) : nil
        waitForExit(of: parent)
        ProcessThrottler.recover(stateFile: state)
        if let llamaPidFile { LlamaServerLLM.killLeftover(pidFile: llamaPidFile) }
        exit(0)
    }

    static func waitForExit(of parent: pid_t) {
        let kq = kqueue()
        var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        guard kevent(kq, &ev, 1, nil, 0, nil) != -1 else { return } // parent already gone
        var out = kevent()
        while true {
            let n = kevent(kq, nil, 0, &out, 1, nil)
            if n > 0 { return }
            if n < 0 && errno != EINTR { return }
        }
    }

    /// Location of the helper: inside the app bundle, or next to the running executable (development builds).
    static func helperURL() -> URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forAuxiliaryExecutable: helperName), fm.isExecutableFile(atPath: u.path) { return u }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent(helperName)
        return fm.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    /// Starts the watchdog for the current process. Returns its pid.
    @discardableResult
    public static func spawn(stateFile: URL, llamaPidFile: URL?) -> pid_t? {
        let p = Process()
        if let helper = helperURL() {
            p.executableURL = helper
            p.arguments = [String(getpid()), stateFile.path] + (llamaPidFile.map { [$0.path] } ?? [])
        } else if let exe = Bundle.main.executableURL {
            p.executableURL = exe
            p.arguments = [flag, String(getpid()), stateFile.path] + (llamaPidFile.map { [$0.path] } ?? [])
        } else {
            return nil
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            return p.processIdentifier
        } catch {
            Log.error("could not start throttle watchdog: \(error)", "intervention")
            return nil
        }
    }
}
