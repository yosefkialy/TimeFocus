import AppKit
import FocusCore
import SwiftUI

/// Borderless floating panel that can receive clicks without activating the app (the user stays where they are).
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
    }
    override var canBecomeKey: Bool { true }
}

/// Shows the drift reminder and the "is this part of your focus?" question near the top of the screen.
final class HUDController {
    private var panel: FloatingPanel?
    private var dismissWork: DispatchWorkItem?

    private func present<V: View>(_ view: V, autoDismiss: TimeInterval?) {
        dismissWork?.cancel()
        panel?.orderOut(nil)
        let hosting = NSHostingView(rootView: AnyView(view.environment(\.layoutDirection, .rightToLeft)))
        let size = hosting.fittingSize
        let p = FloatingPanel(size: NSSize(width: max(size.width, 420), height: size.height))
        p.contentView = hosting
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 14))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
        if let t = autoDismiss {
            let w = DispatchWorkItem { [weak self] in self?.dismiss() }
            dismissWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    func dismiss() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        panel = nil
    }

    func showNudge(_ n: NudgeRequest) {
        let model = AppModel.shared
        let view = NudgeView(request: n, clusters: model.clusters, breaksLeft: model.status.breaksLeft,
                             onBack: { [weak self] in model.backToFocus(); self?.dismiss() },
                             onRelated: { [weak self] cluster in
                                 if let c = cluster { model.assign(n.contextID, to: c) } else { model.allowToday(n.contextID) }
                                 self?.dismiss()
                             },
                             onBreak: { [weak self] in model.takeBreak(); self?.dismiss() },
                             onClose: { [weak self] in self?.dismiss() })
        present(view, autoDismiss: 16)
    }

    func showQuestion(_ q: QuestionRequest) {
        let model = AppModel.shared
        let view = QuestionView(request: q, clusters: model.clusters,
                                onAnswer: { [weak self] cluster in model.assign(q.contextID, to: cluster); self?.dismiss() },
                                onDistraction: { [weak self] in model.markDistraction(q.contextID); self?.dismiss() },
                                onLater: { [weak self] in self?.dismiss() })
        present(view, autoDismiss: 60)
    }
}

struct NudgeView: View {
    let request: NudgeRequest
    let clusters: [ActivityCluster]
    let breaksLeft: Int
    var onBack: () -> Void
    var onRelated: (ClusterID?) -> Void
    var onBreak: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: request.throttleLevel > 0 ? "tortoise.fill" : "scope")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(request.throttleLevel > 0 ? Theme.driftRed : Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.focusNames.isEmpty ? "סטית מהמיקוד" : "חזרה אל: \(request.focusNames.joined(separator: ", "))")
                        .font(.headline)
                    Text("כרגע: \(request.appName)\(request.title.isEmpty ? "" : " — \(request.title)")")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    if let a = request.activityName {
                        Text("זוהה כ: \(a) · \(Fmt.duration(request.driftSeconds))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if request.throttleLevel > 0 {
                HStack(spacing: 8) {
                    Text("היישום מואט").font(.caption).foregroundStyle(Theme.driftRed)
                    ProgressView(value: request.throttleLevel).tint(Theme.driftRed)
                    Text(Fmt.percent(request.throttleLevel)).font(.caption.monospacedDigit())
                }
            }
            HStack(spacing: 8) {
                Button(action: onBack) { Label("חזרה למיקוד", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                Menu {
                    ForEach(request.focusClusterIDs, id: \.self) { id in
                        Button("שייך ל\"\(clusters.first { $0.id == id }?.displayName ?? "")\"") { onRelated(id) }
                    }
                    Divider()
                    Button("מותר היום (בלי לשייך)") { onRelated(nil) }
                } label: { Text("זה קשור למיקוד") }
                .menuStyle(.borderedButton).fixedSize()
                Button(action: onBreak) { Text("הפסקה (\(breaksLeft))") }
                    .disabled(breaksLeft == 0)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct QuestionView: View {
    let request: QuestionRequest
    let clusters: [ActivityCluster]
    var onAnswer: (ClusterID) -> Void
    var onDistraction: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 24)).foregroundStyle(Theme.uncertainAmber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("עוזר לי ללמוד: זה חלק מהמיקוד שלך?").font(.headline)
                    Text("\(request.appName)\(request.title.isEmpty ? "" : " — \(request.title)")")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                ForEach(request.focusClusterIDs.prefix(3), id: \.self) { id in
                    Button("כן — \(clusters.first { $0.id == id }?.displayName ?? "")") { onAnswer(id) }
                        .buttonStyle(.borderedProminent).tint(Theme.focusGreen)
                }
                Button("לא, זו הסחה", action: onDistraction)
                Button("לא עכשיו", action: onLater).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Optional full-screen dimming that deepens with the slowdown level (click-through, all screens).
final class DimOverlay {
    private var windows: [NSWindow] = []
    private var level: Double = 0

    func setLevel(_ newLevel: Double) {
        let target = max(0, min(1, newLevel))
        guard abs(target - level) > 0.01 else { return }
        level = target
        if target <= 0 {
            for w in windows {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
            }
            windows.removeAll()
            return
        }
        if windows.isEmpty {
            for screen in NSScreen.screens {
                let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
                w.backgroundColor = .black
                w.isOpaque = false
                w.ignoresMouseEvents = true
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                w.alphaValue = 0
                w.orderFrontRegardless()
                windows.append(w)
            }
        }
        for w in windows {
            NSAnimationContext.runAnimationGroup { $0.duration = 1.5; w.animator().alphaValue = CGFloat(target * 0.38) }
        }
    }
}
