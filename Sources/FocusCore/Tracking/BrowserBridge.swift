import AppKit
import Foundation

/// Reads the active tab URL of browsers via AppleScript when Accessibility does not expose it.
/// macOS asks the user once per browser ("TimeFocus wants to control …"); a refusal is remembered.
/// NSAppleScript must be used on the main thread.
final class BrowserBridge {
    private var scripts: [String: NSAppleScript] = [:]
    private var deniedUntil: [String: Date] = [:]

    static let chromiumScriptable: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera", "org.chromium.Chromium",
    ]
    static let incognitoAware: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"]

    struct Result { var url: String?; var isPrivate: Bool }

    func canHandle(_ bundleID: String) -> Bool {
        bundleID == "com.apple.Safari" || Self.chromiumScriptable.contains(bundleID)
    }

    /// Must be called on the main thread.
    func activeTab(bundleID: String) -> Result? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canHandle(bundleID) else { return nil }
        if let until = deniedUntil[bundleID], until > Date() { return nil }
        let source: String
        if bundleID == "com.apple.Safari" {
            source = """
            with timeout of 2 seconds
              tell application id "com.apple.Safari"
                if (count of windows) is 0 then return ""
                return "normal" & linefeed & (URL of current tab of front window)
              end tell
            end timeout
            """
        } else if Self.incognitoAware.contains(bundleID) {
            source = """
            with timeout of 2 seconds
              tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set w to front window
                return (mode of w as text) & linefeed & (URL of active tab of w)
              end tell
            end timeout
            """
        } else {
            source = """
            with timeout of 2 seconds
              tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return "normal" & linefeed & (URL of active tab of front window)
              end tell
            end timeout
            """
        }
        let script: NSAppleScript
        if let s = scripts[bundleID] { script = s } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            scripts[bundleID] = s
            script = s
        }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: user denied automation; back off for a day. Other errors: brief back-off.
            deniedUntil[bundleID] = Date().addingTimeInterval(code == -1743 ? 86400 : 60)
            Log.debug("AppleScript URL failed for \(bundleID): \(code)", "tracking")
            return nil
        }
        guard let s = out.stringValue, !s.isEmpty else { return Result(url: nil, isPrivate: false) }
        let lines = s.components(separatedBy: "\n")
        let mode = lines.first ?? "normal"
        let url = lines.count > 1 ? lines[1] : nil
        return Result(url: url, isPrivate: mode.lowercased() == "incognito")
    }
}
