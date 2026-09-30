import AppKit
import FocusCore
import SwiftUI

@main
enum Main {
    static func main() {
        // The same binary doubles as the throttle watchdog (see ThrottleWatchdog).
        ThrottleWatchdog.runIfRequested()
        SnapshotRenderer.runIfRequested()
        TimeFocusApp.main()
    }
}

struct TimeFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environment(\.layoutDirection, .rightToLeft)
        } label: {
            MenuBarLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let status: LiveStatus
    var body: some View {
        let throttling = status.throttleLevel > 0.01
        HStack(spacing: 3) {
            Image(systemName: Theme.verdictSymbol(status.verdict, throttling: throttling))
            if throttling {
                Text(Fmt.percent(status.throttleLevel)).monospacedDigit()
            } else if status.verdict == .offTrack {
                Text(Fmt.clock(status.driftSeconds)).monospacedDigit()
            }
        }
        .onAppear { Log.info("menu bar item shown", "ui") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private let windows = WindowManager()
    private let hud = HUDController()
    private let overlay = DimOverlay()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.openMainWindow = { [weak self] tab in self?.windows.showMain(tab: tab) }
        model.openOnboarding = { [weak self] in self?.windows.showOnboarding() }
        model.onNudge = { [weak self] n in self?.hud.showNudge(n) }
        model.onQuestion = { [weak self] q in self?.hud.showQuestion(q) }
        model.onOverlay = { [weak self] level in self?.overlay.setLevel(level) }
        installSignalHandlers()
        model.start()
        if model.startupError != nil || !model.settings.onboardingCompleted || !Permissions.accessibility {
            windows.showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.setLevel(0)
        model.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showMain(tab: nil)
        return true
    }

    /// SIGTERM/SIGINT (logout, `kill`) → release every paused process before exiting.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.model.shutdown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

/// Owns the AppKit windows hosting SwiftUI (menu-bar apps need explicit window management).
final class WindowManager: NSObject, NSWindowDelegate {
    private var main: NSWindow?
    private var onboarding: NSWindow?

    private func host<V: View>(_ view: V) -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(view.environmentObject(AppModel.shared).environment(\.layoutDirection, .rightToLeft)))
    }

    func showMain(tab: MainTab?) {
        if let tab { AppModel.shared.selectedTab = tab }
        if main == nil {
            let w = NSWindow(contentViewController: host(MainView()))
            w.title = "TimeFocus"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 1100, height: 740))
            w.minSize = NSSize(width: 880, height: 600)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("TimeFocusMainWindow")
            main = w
        }
        present(main)
    }

    func showOnboarding() {
        if onboarding == nil {
            let w = NSWindow(contentViewController: host(OnboardingView(onFinish: { [weak self] in
                self?.onboarding?.close()
                self?.showMain(tab: .today)
            })))
            w.title = "ברוכים הבאים ל-TimeFocus"
            w.styleMask = [.titled, .closable]
            w.setContentSize(NSSize(width: 720, height: 600))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            onboarding = w
        }
        present(onboarding)
    }

    private func present(_ w: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        w?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            let anyVisible = [self.main, self.onboarding].contains { $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
