import AppKit
import FocusCore
import SwiftUI

/// Developer tool: renders every screen to PNG without showing anything on screen.
///   TIMEFOCUS_SUPPORT_DIR=/tmp/demo TimeFocus --snapshot /tmp/shots
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { return }
        let out = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.reloadClusters()
        model.loadEvidenceNow()
        model.refreshStats()
        model.refreshEnvironment()
        model.hasAccessibility = true
        model.notificationsAuthorized = true

        let work = model.clusters.first { $0.name == "עבודה" } ?? model.clusters.first
        let fun = model.clusters.first { $0.name == "בידור" } ?? model.clusters.last
        let start = Date().startOfDay.addingTimeInterval(9 * 3600)
        let focus = ActiveFocus(clusterIDs: Set([work?.id].compactMap { $0 }), start: start, end: start.addingTimeInterval(4 * 3600), isManual: false)
        var onTrack = LiveStatus()
        onTrack.appName = "Code"; onTrack.bundleID = "com.microsoft.VSCode"; onTrack.title = "FocusEngine.swift — time_focus"
        onTrack.activityID = work?.id; onTrack.activityName = work?.displayName; onTrack.confidence = 0.94; onTrack.novelty = 0.05
        onTrack.source = .model; onTrack.verdict = .onTrack; onTrack.focus = focus; onTrack.focusNames = [work?.displayName ?? ""]
        onTrack.breaksLeft = 5; onTrack.hasAccessibility = true
        var drifting = onTrack
        drifting.appName = "Google Chrome"; drifting.bundleID = "com.google.Chrome"; drifting.title = "Funny cats compilation 2026 - YouTube"
        drifting.host = "youtube.com"; drifting.activityID = fun?.id; drifting.activityName = fun?.displayName; drifting.confidence = 0.91
        drifting.verdict = .offTrack; drifting.driftSeconds = 142; drifting.throttleLevel = 0.37

        func shot<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat?) {
            let root = view.environmentObject(model).environment(\.layoutDirection, .rightToLeft)
            let hosting = NSHostingView(rootView: AnyView(root.frame(width: width, height: height)))
            let size = height.map { CGSize(width: width, height: $0) } ?? CGSize(width: width, height: hosting.fittingSize.height)
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 20000, y: 20000), size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .aqua)
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
            print("wrote \(name).png")
        }

        model.status = onTrack
        if let engine = model.engine {
            engine.pipeline.refreshCounts()
            model.learning = engine.pipeline.status
        }
        for tab in MainTab.allCases {
            model.selectedTab = tab
            shot("main-\(tab.rawValue)", MainView(), width: 1180, height: 820)
        }
        // one activity type with its first window opened (prefer a window whose title says nothing, like "Claude")
        if let c = model.clusters.first(where: { c in model.evidence.clusters[c.id]?.windows.contains { !$0.hasInformativeTitle } ?? false })
            ?? model.clusters.first {
            let w = model.evidence.clusters[c.id]?.windows.first { !$0.hasInformativeTitle } ?? model.evidence.clusters[c.id]?.windows.first
            shot("activity-card-expanded", ClusterCard(cluster: c, expandedWindowID: w?.id).padding(20), width: 560, height: nil)
        }
        shot("timeline-yesterday", TimelineView(day: Date().startOfDay.addingTimeInterval(-86400)), width: 1000, height: 760)
        shot("menubar-ontrack", MenuBarView(), width: 360, height: nil)
        model.status = drifting
        shot("menubar-drifting", MenuBarView(), width: 360, height: nil)
        let nudge = NudgeRequest(contextID: 1, appName: drifting.appName, title: drifting.title, activityName: fun?.displayName,
                                 focusNames: [work?.displayName ?? ""], focusClusterIDs: [work?.id].compactMap { $0 },
                                 driftSeconds: 142, throttleLevel: 0.37, isRepeat: false)
        shot("hud-nudge", NudgeView(request: nudge, clusters: model.clusters, breaksLeft: 5, onBack: {}, onRelated: { _ in }, onBreak: {}, onClose: {}),
             width: 460, height: nil)
        let q = QuestionRequest(contextID: 2, appName: "Google Chrome", title: "Kaggle - Linear Regression Tutorial", focusClusterIDs: [work?.id].compactMap { $0 },
                                focusNames: [work?.displayName ?? ""], suggestedClusterID: nil, suggestedName: nil)
        shot("hud-question", QuestionView(request: q, clusters: model.clusters, onAnswer: { _ in }, onDistraction: {}, onLater: {}),
             width: 460, height: nil)
        shot("onboarding", OnboardingView(onFinish: {}), width: 720, height: 600)
        shot("settings-ocr", Form { Section("מעקב") { OCRSettings(interval: .constant(60)) } }.formStyle(.grouped), width: 640, height: 260)
        exit(0)
    }
}
