import AppKit
import ApplicationServices
import FocusML
import Foundation

public enum CaptureReason: String {
    case tick, appSwitch, windowChange, wake, manual
}

/// One observation of what the user is doing right now.
public struct ActivitySnapshot {
    public var time: Date
    /// Seconds since the previous snapshot — this interval belongs to the PREVIOUS activity.
    public var interval: TimeInterval
    public var input: InputDelta
    public var secondsSinceInput: Double
    public var locked: Bool
    public var pid: pid_t
    public var bundleID: String
    public var appName: String
    public var title: String
    public var url: String?
    public var host: String?
    public var urlPath: String?
    public var documentPath: String?
    public var text: String?
    public var mediaPlaying: Bool
    public var isPrivate: Bool
    public var isOwnApp: Bool
    public var isFullScreen: Bool
    public var key: String
    public var reason: CaptureReason

    public init(time: Date, interval: TimeInterval, input: InputDelta = InputDelta(), secondsSinceInput: Double = 0,
                locked: Bool = false, pid: pid_t, bundleID: String, appName: String, title: String, url: String? = nil,
                host: String? = nil, urlPath: String? = nil, documentPath: String? = nil, text: String? = nil,
                mediaPlaying: Bool = false, isPrivate: Bool = false, isOwnApp: Bool = false, isFullScreen: Bool = false,
                key: String, reason: CaptureReason = .tick) {
        self.time = time; self.interval = interval; self.input = input; self.secondsSinceInput = secondsSinceInput
        self.locked = locked; self.pid = pid; self.bundleID = bundleID; self.appName = appName; self.title = title
        self.url = url; self.host = host; self.urlPath = urlPath; self.documentPath = documentPath; self.text = text
        self.mediaPlaying = mediaPlaying; self.isPrivate = isPrivate; self.isOwnApp = isOwnApp
        self.isFullScreen = isFullScreen; self.key = key; self.reason = reason
    }
}

public protocol ActivityMonitorDelegate: AnyObject {
    /// Called on the tracking queue.
    func monitor(_ monitor: ActivityMonitor, didCapture snapshot: ActivitySnapshot)
    /// OCR text for a context arrived (tracking queue).
    func monitor(_ monitor: ActivityMonitor, didRecognizeText text: String, forKey key: String)
}

/// Observes the frontmost app/window and produces `ActivitySnapshot`s on a private serial queue.
public final class ActivityMonitor {
    public let queue = DispatchQueue(label: "timefocus.tracking", qos: .userInitiated)
    public weak var delegate: ActivityMonitorDelegate?
    private let settings: SettingsStore

    private struct FrontApp { var pid: pid_t; var bundleID: String; var name: String }
    private let lock = NSLock()
    private var front: FrontApp?
    private var screenLocked = false
    private var sleeping = false

    // tracking-queue state
    private var timer: DispatchSourceTimer?
    private var lastCounters = InputCounters.read()
    private var lastSnapshotTime = Date()
    private var textCapturedAt: [String: Date] = [:]
    private var ocrAt: [String: Date] = [:]
    /// Characters and words of the last Accessibility text of each context (OCR then adds only what it lacks).
    private var axTextChars: [String: Int] = [:]
    private var axWords: [String: Set<String>] = [:]
    /// Lines each app/site shows in most of its windows (menus, navigation, toolbars) — dropped from window text.
    private let boilerplate = BoilerplateFilter()
    /// How each window's content area was last found and read (logged when it changes).
    private var regionNotes: [String: String] = [:]
    private var urlScriptAt: [String: Date] = [:]
    private var lastURLByBundle: [String: (url: String?, isPrivate: Bool, at: Date)] = [:]
    private var enhancedPIDs = Set<pid_t>()
    private var urlCache: [String: String] = [:]
    private var capturing = true
    private var pendingCapture: DispatchWorkItem?
    private var running = false

    // main-thread state
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var observers: [NSObjectProtocol] = []
    private let browser = BrowserBridge()
    private let ocr: OCRService
    private let ownBundleID = AppPaths.ownBundleID
    /// Set by the engine: whether a pid is currently being slowed down (skip expensive IPC with it).
    public var isThrottled: ((pid_t) -> Bool)?

    public init(settings: SettingsStore, paths: AppPaths = .default) {
        self.settings = settings
        ocr = OCRService(paths: paths)
    }

    public static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    // MARK: lifecycle

    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !running else { return }
        running = true
        // The messaging timeout set on one element is not inherited by its windows/children: set the global default
        // so no AX call to a hung (or throttled) app can block tracking for the default ~6 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXReader.messagingTimeout)
        queue.async { [weak self] in self?.capturing = true }
        updateFrontApp(NSWorkspace.shared.frontmostApplication)
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateFrontApp(app)
            self?.captureSoon(.appSwitch, delay: 0.15)
        })
        for (name, locked) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setLocked(locked)
            })
        }
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lock.lock(); self?.sleeping = true; self?.lock.unlock()
            self?.captureSoon(.tick, delay: 0)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lock.lock(); self?.sleeping = false; self?.lock.unlock()
            self?.queue.async { self?.resetBaseline() }
            self?.captureSoon(.wake, delay: 1)
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(true)
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(false)
        })
        queue.async { [weak self] in
            guard let self else { return }
            self.resetBaseline()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            let interval = max(1, self.settings.current.tickSeconds)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(300))
            t.setEventHandler { [weak self] in self?.capture(.tick) }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        running = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        removeAXObserver()
        queue.sync {
            capturing = false // nothing may capture (and re-arm a slowdown) after stop
            pendingCapture?.cancel()
            pendingCapture = nil
            timer?.cancel()
            timer = nil
        }
    }

    private func setLocked(_ locked: Bool) {
        lock.lock(); screenLocked = locked; lock.unlock()
        if !locked { queue.async { [weak self] in self?.resetBaseline() } }
        captureSoon(locked ? .tick : .wake, delay: 0.2)
    }

    private func resetBaseline() {
        lastCounters = InputCounters.read()
        lastSnapshotTime = Date()
    }

    private func updateFrontApp(_ app: NSRunningApplication?) {
        guard let app else { return }
        lock.lock()
        front = FrontApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "unknown.\(app.processIdentifier)",
                         name: app.localizedName ?? app.bundleIdentifier ?? "App")
        lock.unlock()
        installAXObserver(pid: app.processIdentifier)
    }

    // MARK: AX observer (window focus + title changes → immediate capture)

    private func installAXObserver(pid: pid_t) {
        guard AXIsProcessTrusted(), pid != observedPID else { return }
        removeAXObserver()
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<ActivityMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.captureSoon(.windowChange, delay: 0.5)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else { return }
        let app = AXReader.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXTitleChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPID = pid
    }

    private func removeAXObserver() {
        if let o = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        axObserver = nil
        observedPID = 0
    }

    // MARK: capture

    /// Coalesces bursts of events (tab switching, title animations) into one capture.
    public func captureSoon(_ reason: CaptureReason, delay: TimeInterval) {
        queue.async { [weak self] in
            guard let self, self.capturing else { return }
            self.pendingCapture?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.capture(reason) }
            self.pendingCapture = item
            self.queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func capture(_ reason: CaptureReason) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard capturing else { return }
        let s = settings.current
        let now = Date()
        let counters = InputCounters.read()
        let input = counters.delta(since: lastCounters)
        lastCounters = counters
        // After sleep the interval can be huge; never attribute more than a few ticks.
        let interval = min(now.timeIntervalSince(lastSnapshotTime), max(s.tickSeconds * 2.5, 10))
        lastSnapshotTime = now

        lock.lock()
        let app = front
        let locked = screenLocked || sleeping
        lock.unlock()

        let idle = SystemSignals.secondsSinceLastInput()
        guard let app, s.trackingEnabled else { return }
        var snap = ActivitySnapshot(time: now, interval: interval, input: input, secondsSinceInput: idle, locked: locked,
                                    pid: app.pid, bundleID: app.bundleID, appName: app.name, title: "", url: nil, host: nil,
                                    urlPath: nil, documentPath: nil, text: nil, mediaPlaying: false, isPrivate: false,
                                    isOwnApp: app.bundleID == ownBundleID, isFullScreen: false, key: "", reason: reason)
        if locked || ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains(app.bundleID) {
            snap.locked = true
            snap.key = "locked"
            delegate?.monitor(self, didCapture: snap)
            return
        }

        let excluded = s.excludedBundleIDs.contains(app.bundleID)
        var rawTitle = ""
        var focusedWindow: AXUIElement? = nil
        // what lies under the middle of the window, and the page it shows (browsers, Electron apps) — looked up at most
        // once per capture, by hit-testing (a walk of the tree is the fallback)
        var hitChain: [AXUIElement]? = nil
        func chain(_ win: AXUIElement) -> [AXUIElement] {
            if hitChain == nil { hitChain = ContentLocator.chain(under: win, pid: app.pid) }
            return hitChain ?? []
        }
        var webAreaLookedUp = false
        var webAreaElement: AXUIElement? = nil
        func webArea(_ win: AXUIElement) -> AXUIElement? {
            if !webAreaLookedUp {
                webAreaLookedUp = true
                webAreaElement = chain(win).last { AXReader.role($0) == "AXWebArea" } ?? AXReader.largestWebArea(in: win)
            }
            return webAreaElement
        }
        if AXIsProcessTrusted(), !excluded {
            if s.enhanceChromiumAccessibility, !enhancedPIDs.contains(app.pid) {
                enhancedPIDs.insert(app.pid)
                AXReader.enableEnhancedAccessibility(pid: app.pid)
            }
            if let win = AXReader.focusedWindow(pid: app.pid) {
                rawTitle = AXReader.windowTitle(win) ?? ""
                snap.documentPath = AXReader.documentPath(win)
                snap.isFullScreen = AXReader.isFullScreen(win)
                if s.captureBrowserURLs, ContextNormalizer.isBrowser(app.bundleID) {
                    snap.url = webArea(win).flatMap(AXReader.url(ofWebArea:)) ?? AXReader.addressBarText(window: win)
                }
                if ContextNormalizer.isPrivateWindowTitle(rawTitle) { snap.isPrivate = true }
                snap.title = ContextNormalizer.cleanTitle(rawTitle, appName: app.name)
                // text is captured below once the context key is known
                focusedWindow = win
            }
        }
        // AppleScript fallback for browser URLs (main thread, rate-limited). Never script an app that is currently
        // being slowed down: Apple Events to a paused process would block the main thread.
        let throttled = isThrottled?(app.pid) ?? false
        if s.captureBrowserURLs, s.useAppleScriptForURLs, !excluded, !throttled, ContextNormalizer.isBrowser(app.bundleID),
           snap.url == nil || BrowserBridge.incognitoAware.contains(app.bundleID) {
            if let r = scriptedURL(bundleID: app.bundleID, force: reason != .tick) {
                if snap.url == nil { snap.url = r.url }
                if r.isPrivate { snap.isPrivate = true }
            }
        }
        // Same window title ⇒ same page: remember URLs so a window keeps its identity when a URL read fails
        // (e.g. while the browser is being slowed down and is not scripted).
        let urlKey = app.bundleID + "|" + snap.title
        if let u = snap.url, !u.isEmpty {
            if !snap.isPrivate {
                if urlCache.count > 2000 { urlCache.removeAll() }
                urlCache[urlKey] = u
            }
        } else if ContextNormalizer.isBrowser(app.bundleID), !snap.isPrivate, let cached = urlCache[urlKey] {
            snap.url = cached
        }
        let parsed = ContextNormalizer.parseURL(snap.url)
        snap.host = parsed.host
        snap.urlPath = parsed.path
        if let h = parsed.host, s.excludedHosts.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { snap.isPrivate = true }
        if excluded { snap.isPrivate = true }
        if snap.isPrivate {
            snap.title = ""
            snap.url = nil
            snap.urlPath = nil
            snap.documentPath = nil
        }
        if snap.title.isEmpty && !snap.isPrivate { snap.title = snap.host ?? "" }

        snap.key = snap.isPrivate
            ? ContextNormalizer.key(bundleID: app.bundleID, host: nil, path: nil, cleanTitle: "#private")
            : ContextNormalizer.key(bundleID: app.bundleID, host: snap.host, path: snap.urlPath, cleanTitle: snap.title)

        // media playback (video/lecture) = the user is present even without input
        let assertionPIDs = SystemSignals.pidsPreventingDisplaySleep()
        if !assertionPIDs.isEmpty {
            let procs = ProcessTree.allProcesses()
            let family = Set(ProcessTree.descendants(of: app.pid, in: procs))
            var playing = !assertionPIDs.isDisjoint(with: family)
            if !playing, app.bundleID == "com.apple.Safari" {
                let names = Dictionary(procs.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
                playing = assertionPIDs.contains { (names[$0] ?? "").contains("WebKit") }
            }
            snap.mediaPlaying = playing
        }

        // Window content — read only from the content area (a page's main part, a document pane), never from what
        // frames it: tabs, bookmarks, sidebars and menus show the same text whatever the window is used for.
        let readable = !snap.isPrivate && !snap.isOwnApp && !throttled
        let key = snap.key
        let template = app.bundleID + "|" + (snap.host ?? "")
        let textDue = readable && s.captureAXText && focusedWindow != nil
            && now.timeIntervalSince(textCapturedAt[key] ?? .distantPast) >= s.axTextRefreshSeconds
        // OCR reads what Accessibility cannot (canvas apps, PDFs, images, slides in a video); less often where
        // Accessibility already gives plenty of text
        let ocrInterval = s.ocrIntervalSeconds * ((axTextChars[key] ?? 0) >= 1500 ? 3 : 1)
        let ocrDue = readable && s.enableOCR && OCRService.hasPermission
            && now.timeIntervalSince(ocrAt[key] ?? .distantPast) >= ocrInterval
        var region: ContentRegion? = nil
        if textDue || ocrDue, let win = focusedWindow {
            let isBrowser = ContextNormalizer.isBrowser(app.bundleID)
            region = ContentLocator.locate(window: win, chain: chain(win), webArea: isBrowser ? webArea(win) : nil, isBrowser: isBrowser)
        }

        // window text (Accessibility), refreshed per context at most every N seconds: what is shown in the content area
        if textDue, let win = focusedWindow {
            var raw = AXReader.collectText(root: region?.element ?? win, within: region?.frame)
            var method = "walk"
            if raw.count < 200, let r = region, let web = r.webArea, let t = AXReader.visibleWebText(web, in: r.frame), t.count > raw.count {
                raw = t // pages too deep for the walk's budget: the text the page shows inside the region, in a few calls
                method = "markers"
            }
            // nothing yet (a page still building its tree): look again in ~5 s instead of a full refresh interval
            textCapturedAt[key] = raw.isEmpty ? now.addingTimeInterval(min(0, 5 - s.axTextRefreshSeconds)) : now
            // (pages wrap numbers and names in invisible direction marks — "‫24.4K‬ מנויים")
            let shown = raw.split(whereSeparator: \.isNewline).map { OCRFusion.clean(String($0)) }.filter { !$0.isEmpty }
            let lines = boilerplate.filter(shown, template: template, window: key)
            axTextChars[key] = lines.reduce(0) { $0 + $1.count }
            axWords[key] = Set(lines.flatMap { TextTokenizer.words($0, maxTokens: 400) })
            if !lines.isEmpty { snap.text = ContextNormalizer.redact(lines.joined(separator: "\n")) }
            // how the content area was found and read — structure and counts only, once per window and change
            let note = "\(region?.kind.rawValue ?? "none") \(method)"
            if regionNotes[key] != note {
                if regionNotes.count > 500 { regionNotes.removeAll() }
                regionNotes[key] = note
                let r = region?.frame ?? .zero
                Log.info(String(format: "content %@: %@ %@, hit chain %d, region %.0fx%.0f, %d lines (%d chars) of %d",
                                app.bundleID, region?.kind.rawValue ?? "none", method, chain(win).count, r.width, r.height,
                                lines.count, axTextChars[key] ?? 0, raw.count), "tracking")
            }
        }

        // optional OCR (asynchronous; the result arrives later via the delegate)
        if ocrDue {
            ocrAt[key] = now
            let hebrew = s.interfaceLanguage.hasPrefix("he") || OCRFusion.hebrewLetterCount(snap.title) > 0
                || Locale.preferredLanguages.contains { $0.hasPrefix("he") }
            let kind = region?.kind.rawValue ?? "none"
            ocr.recognize(pid: app.pid, key: key, region: region?.frame, regionIsContent: region?.isContent ?? false,
                          hebrew: hebrew) { [weak self] reading in
                guard let self, let reading else { return }
                self.queue.async {
                    var lines = self.boilerplate.filter(reading.lines, template: template, window: key)
                    // lines Accessibility already read add nothing
                    if let known = self.axWords[key], !known.isEmpty { lines = lines.filter { Self.isNovel($0, known: known) } }
                    // counts only — window text never goes to the log
                    Log.info(String(format: "OCR %@: %d lines → %d new, tesseract %@, %.2f s", kind, reading.lines.count, lines.count,
                                    reading.usedTesseract ? "yes" : "no", reading.seconds), "tracking")
                    guard !lines.isEmpty else { return }
                    self.delegate?.monitor(self, didRecognizeText: ContextNormalizer.redact(lines.joined(separator: "\n")), forKey: key)
                }
            }
        }
        if textCapturedAt.count > 5000 { textCapturedAt.removeAll() }
        if ocrAt.count > 5000 { ocrAt.removeAll() }
        if axWords.count > 400 { axWords.removeAll(); axTextChars.removeAll() }
        delegate?.monitor(self, didCapture: snap)
    }

    /// A line is novel unless most of its words are already in the window's Accessibility text.
    public static func isNovel(_ line: String, known: Set<String>) -> Bool {
        let words = TextTokenizer.words(line, maxTokens: 60).filter { $0.count >= 2 }
        guard !words.isEmpty else { return false }
        return Double(words.filter { known.contains($0) }.count) < 0.7 * Double(words.count)
    }

    // MARK: boilerplate memory (tracking queue)

    public var boilerplateState: BoilerplateFilter.State {
        dispatchPrecondition(condition: .onQueue(queue))
        return boilerplate.state
    }

    public func restoreBoilerplate(_ state: BoilerplateFilter.State) {
        dispatchPrecondition(condition: .onQueue(queue))
        boilerplate.restore(state)
    }

    public func resetBoilerplate() {
        dispatchPrecondition(condition: .onQueue(queue))
        boilerplate.reset()
        axWords.removeAll()
        axTextChars.removeAll()
    }

    /// Runs the browser AppleScript on the main thread with a hard timeout.
    private func scriptedURL(bundleID: String, force: Bool) -> BrowserBridge.Result? {
        let now = Date()
        if !force, let last = lastURLByBundle[bundleID], now.timeIntervalSince(last.at) < 8 {
            return BrowserBridge.Result(url: last.url, isPrivate: last.isPrivate)
        }
        if let last = urlScriptAt[bundleID], now.timeIntervalSince(last) < 1.0, let cached = lastURLByBundle[bundleID] {
            return BrowserBridge.Result(url: cached.url, isPrivate: cached.isPrivate)
        }
        urlScriptAt[bundleID] = now
        let sem = DispatchSemaphore(value: 0)
        var result: BrowserBridge.Result?
        DispatchQueue.main.async { [browser] in
            result = browser.activeTab(bundleID: bundleID)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 2.5) == .success else { return nil }
        if let r = result { lastURLByBundle[bundleID] = (r.url, r.isPrivate, now) }
        return result
    }

    /// Activates an app and (best effort) raises the window with the given title.
    public static func bringToFront(pid: pid_t, windowTitle: String?) {
        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            app.activate(options: [.activateAllWindows])
            if AXIsProcessTrusted() {
                DispatchQueue.global(qos: .userInitiated).async { AXReader.raiseWindow(pid: pid, titled: windowTitle) }
            }
        }
    }
}
