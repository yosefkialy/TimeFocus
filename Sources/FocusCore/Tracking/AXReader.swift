import AppKit
import ApplicationServices

/// Thin, defensive wrapper over the macOS Accessibility API (requires the Accessibility permission).
/// All calls use a short messaging timeout so an unresponsive app can never stall tracking.
enum AXReader {
    static let messagingTimeout: Float = 0.25

    static func application(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        guard let v = value(el, attr) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = value(el, attr) else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func children(_ el: AXUIElement, visibleOnly: Bool = false) -> [AXUIElement] {
        if visibleOnly, let v = value(el, "AXVisibleChildren") as? [AXUIElement], !v.isEmpty { return v }
        return (value(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        if let w = element(app, kAXFocusedWindowAttribute as String) { return w }
        return element(app, kAXMainWindowAttribute as String)
    }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute as String) ?? "" }

    /// Asks Chromium/Electron apps to expose their full accessibility tree (needed to read page text).
    static func enableEnhancedAccessibility(pid: pid_t) {
        let app = application(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Breadth-first search for the first element with the given role.
    static func find(role target: String, in root: AXUIElement, maxNodes: Int = 250, budget: TimeInterval = 0.3) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let deadline = Date().addingTimeInterval(budget) // an unresponsive app must never stall tracking
        while !queue.isEmpty, visited < maxNodes, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            if role(el) == target { return el }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    /// URL of the web page shown in a browser window (Safari / Chromium / Firefox expose AXURL on the web area).
    static func webURL(window: AXUIElement) -> String? {
        guard let area = find(role: "AXWebArea", in: window, maxNodes: 300) else { return nil }
        if let v = value(area, "AXURL") {
            if let u = v as? URL { return u.absoluteString }
            if let s = v as? String { return s }
        }
        return nil
    }

    /// Reads the address-bar text field when the web area does not expose a URL.
    static func addressBarText(window: AXUIElement) -> String? {
        var queue: [AXUIElement] = [window]
        var visited = 0
        let deadline = Date().addingTimeInterval(0.3)
        while !queue.isEmpty, visited < 200, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            let r = role(el)
            if r == "AXTextField" || r == "AXComboBox" {
                let desc = (string(el, kAXDescriptionAttribute as String) ?? "") + " " + (string(el, kAXIdentifierAttribute as String) ?? "")
                let d = desc.lowercased()
                if d.contains("address") || d.contains("url") || d.contains("location") || d.contains("כתובת") {
                    if let v = string(el, kAXValueAttribute as String), !v.isEmpty { return v }
                }
            }
            if r == "AXWebArea" { continue } // do not descend into page content
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    private static let skipRoles: Set<String> = [
        "AXSecureTextField", "AXMenuBar", "AXMenu", "AXMenuItem", "AXScrollBar", "AXToolbar", "AXTabGroup",
        "AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor", "AXColorWell",
        "AXDisclosureTriangle", "AXMenuButton", "AXSplitter", "AXGrowArea", "AXRuler",
    ]

    /// Collects visible text from a window within node/character budgets. Password fields are never read.
    static func collectText(window: AXUIElement, maxChars: Int = 2500, maxNodes: Int = 350, budget: TimeInterval = 0.6) -> String {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        var parts: [String] = []
        var total = 0
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(budget)
        while head < queue.count, head < maxNodes, total < maxChars, Date() < deadline {
            let (el, depth) = queue[head]
            head += 1
            let r = role(el)
            if skipRoles.contains(r) { continue }
            if (string(el, kAXSubroleAttribute as String) ?? "") == "AXSecureTextField" { continue }
            var candidates: [String] = []
            switch r {
            case "AXStaticText", "AXHeading":
                if let v = string(el, kAXValueAttribute as String) { candidates.append(v) }
                if r == "AXHeading", let t = string(el, kAXTitleAttribute as String) { candidates.append(t) }
            case "AXTextArea", "AXTextField":
                if let v = string(el, kAXValueAttribute as String) { candidates.append(String(v.prefix(800))) }
            case "AXWebArea", "AXLink", "AXImage":
                if let t = string(el, kAXTitleAttribute as String) { candidates.append(t) }
                if r == "AXImage", let d = string(el, kAXDescriptionAttribute as String) { candidates.append(d) }
            case "AXCell", "AXRow":
                if let t = string(el, kAXTitleAttribute as String) { candidates.append(t) }
            default:
                break
            }
            for c in candidates {
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count >= 2, seen.insert(t).inserted else { continue }
                parts.append(t)
                total += t.count + 1
            }
            if depth < 40 { queue.append(contentsOf: children(el, visibleOnly: true).map { ($0, depth + 1) }) }
        }
        return String(parts.joined(separator: "\n").prefix(maxChars))
    }

    static func windowTitle(_ window: AXUIElement) -> String? { string(window, kAXTitleAttribute as String) }
    static func documentPath(_ window: AXUIElement) -> String? { string(window, kAXDocumentAttribute as String) }
    static func isFullScreen(_ window: AXUIElement) -> Bool { bool(window, "AXFullScreen") ?? false }

    /// Brings a specific window of an app to the front (used by "back to focus").
    @discardableResult
    static func raiseWindow(pid: pid_t, titled title: String?) -> Bool {
        let app = application(pid)
        guard let windows = value(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return false }
        let target = windows.first { w in title.map { windowTitle(w) == $0 } ?? false } ?? windows.first
        guard let win = target else { return false }
        return AXUIElementPerformAction(win, kAXRaiseAction as CFString) == .success
    }
}
