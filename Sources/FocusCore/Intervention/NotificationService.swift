import AppKit
import Carbon.HIToolbox
import Foundation
import UserNotifications

/// macOS notifications with quick actions. Only used when running as a real .app bundle.
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public enum Action: String {
        case back = "TF_BACK", related = "TF_RELATED", pause = "TF_BREAK", open = "TF_OPEN"
    }

    public var onAction: ((Action, [AnyHashable: Any]) -> Void)?
    private var center: UNUserNotificationCenter?
    public private(set) var authorized = false

    public static var canUseNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public override init() {
        super.init()
        guard Self.canUseNotifications else { return }
        let c = UNUserNotificationCenter.current()
        center = c
        c.delegate = self
        let back = UNNotificationAction(identifier: Action.back.rawValue, title: "חזרה למיקוד", options: [.foreground])
        let related = UNNotificationAction(identifier: Action.related.rawValue, title: "זה קשור למיקוד", options: [])
        let pause = UNNotificationAction(identifier: Action.pause.rawValue, title: "הפסקה קצרה", options: [])
        let drift = UNNotificationCategory(identifier: "DRIFT", actions: [back, related, pause], intentIdentifiers: [], options: [])
        let info = UNNotificationCategory(identifier: "INFO", actions: [], intentIdentifiers: [], options: [])
        c.setNotificationCategories([drift, info])
        c.getNotificationSettings { [weak self] s in self?.authorized = s.authorizationStatus == .authorized }
    }

    public func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let center else { completion?(false); return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            self?.authorized = ok
            completion?(ok)
        }
    }

    public func postDrift(id: String, title: String, body: String, userInfo: [String: Any]) {
        post(id: id, title: title, body: body, category: "DRIFT", userInfo: userInfo, sound: true)
    }

    public func postInfo(id: String, title: String, body: String) {
        post(id: id, title: title, body: body, category: "INFO", userInfo: ["open": true], sound: false)
    }

    private func post(id: String, title: String, body: String, category: String, userInfo: [String: Any], sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = userInfo
        if sound { content.sound = .default }
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    public func removeDelivered(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action: Action
        switch response.actionIdentifier {
        case Action.back.rawValue: action = .back
        case Action.related.rawValue: action = .related
        case Action.pause.rawValue: action = .pause
        default: action = .open
        }
        DispatchQueue.main.async { self.onAction?(action, info) }
        completionHandler()
    }
}

/// System-wide hotkey (Carbon; no permission required). Default: ⌃⌥⌘. = emergency stop of all interventions.
public final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    public init?(keyCode: UInt32 = UInt32(kVK_ANSI_Period), modifiers: UInt32 = UInt32(cmdKey | optionKey | controlKey),
                 handler: @escaping () -> Void) {
        self.handler = handler
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { GlobalHotKey.instances[hk.id]?.handler() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        guard status == noErr else { return nil }
        let hkID = EventHotKeyID(signature: OSType(0x5446_4F43), id: id) // 'TFOC'
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
        Self.instances[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        Self.instances[id] = nil
    }
}

/// Permission status and helpers (the user always grants permissions themselves in System Settings).
public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
        case notifications = "notifications"
    }

    public static func openSettings(_ pane: Pane) {
        let url: URL
        if pane == .notifications {
            url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        }
        NSWorkspace.shared.open(url)
    }
}
