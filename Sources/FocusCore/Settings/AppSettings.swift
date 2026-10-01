import Foundation

public enum Strictness: String, Codable, CaseIterable, Identifiable {
    case gentle, normal, strict
    public var id: String { rawValue }

    /// Timing of the escalation ladder for one drift episode.
    public var profile: InterventionProfile {
        switch self {
        case .gentle: return InterventionProfile(nudgeAfter: 30, throttleAfter: 120, rampSeconds: 600, renudgeEvery: 300, offTrackThreshold: 0.8)
        case .normal: return InterventionProfile(nudgeAfter: 15, throttleAfter: 45, rampSeconds: 300, renudgeEvery: 180, offTrackThreshold: 0.72)
        case .strict: return InterventionProfile(nudgeAfter: 5, throttleAfter: 15, rampSeconds: 120, renudgeEvery: 90, offTrackThreshold: 0.65)
        }
    }
}

public struct InterventionProfile: Equatable {
    /// Seconds of confident drift before the first reminder.
    public var nudgeAfter: Double
    /// Seconds of confident drift before the slowdown starts.
    public var throttleAfter: Double
    /// Seconds from slowdown start until the maximum slowdown is reached.
    public var rampSeconds: Double
    /// Seconds between repeated reminders while still drifting.
    public var renudgeEvery: Double
    /// Minimal probability that the activity is outside the plan before counting it as drift.
    public var offTrackThreshold: Double
}

public enum NudgeStyle: String, Codable, CaseIterable, Identifiable {
    case notification, banner, both, none
    public var id: String { rawValue }
}

public enum LLMBackendKind: String, Codable, CaseIterable, Identifiable {
    case automatic, appleIntelligence, llamaServer, openAICompatible, none
    public var id: String { rawValue }
}

/// User-configurable settings (persisted as JSON in UserDefaults).
public struct AppSettings: Codable, Equatable {
    // Tracking
    public var trackingEnabled = true
    public var tickSeconds: Double = 4
    public var captureAXText = true
    public var axTextRefreshSeconds: Double = 20
    public var enableOCR = false
    public var ocrIntervalSeconds: Double = 60
    public var captureBrowserURLs = true
    public var useAppleScriptForURLs = true
    public var enhanceChromiumAccessibility = true
    public var excludedBundleIDs: [String] = AppSettings.defaultExcludedApps
    public var excludedHosts: [String] = []
    public var awayAfterSeconds: Double = 120
    public var textRetentionDays = 14
    public var segmentRetentionDays = 180

    // Learning
    public var minLearningDays = 3
    public var minLearningHours: Double = 6
    public var learningIdleMinutes: Double = 5
    public var learnOnlyOnPower = false
    public var embeddingModelID = "multilingual-e5-small"
    public var llmBackend: LLMBackendKind = .automatic
    public var llamaServerPath: String = ""
    public var llmModelFile: String = ""
    public var openAIBaseURL = "http://127.0.0.1:11434/v1"
    public var openAIModel = "gemma3:4b"
    public var maxLLMCallsPerRun = 120
    public var interfaceLanguage = "he"

    // Focus & interventions
    public var strictness: Strictness = .normal
    public var nudgeStyle: NudgeStyle = .both
    public var throttlingEnabled = true
    public var maxThrottle: Double = 0.85
    public var dimOverlayEnabled = false
    public var neverThrottleBundleIDs: [String] = AppSettings.defaultNeverThrottle
    public var alwaysAllowedClusterIDs: [Int64] = []
    public var askWhenUncertain = true
    public var breakMinutes: Double = 5
    public var maxBreaksPerDay = 6
    public var morningPlanPrompt = true
    public var emergencyHotkeyEnabled = true
    public var launchAtLogin = false
    public var onboardingCompleted = false

    public init() {}

    public static let defaultExcludedApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal",
    ]

    public static let defaultNeverThrottle = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.SystemSettings", "com.apple.ActivityMonitor",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dock", "com.apple.loginwindow",
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp",
        "com.timefocus.app",
    ]

    // Codable with defaults for forward compatibility: missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ k: CodingKeys, _ v: inout T) { if let x = try? c.decode(T.self, forKey: k) { v = x } }
        d(.trackingEnabled, &trackingEnabled); d(.tickSeconds, &tickSeconds); d(.captureAXText, &captureAXText)
        d(.axTextRefreshSeconds, &axTextRefreshSeconds); d(.enableOCR, &enableOCR); d(.ocrIntervalSeconds, &ocrIntervalSeconds)
        d(.captureBrowserURLs, &captureBrowserURLs); d(.useAppleScriptForURLs, &useAppleScriptForURLs)
        d(.enhanceChromiumAccessibility, &enhanceChromiumAccessibility); d(.excludedBundleIDs, &excludedBundleIDs)
        d(.excludedHosts, &excludedHosts); d(.awayAfterSeconds, &awayAfterSeconds); d(.textRetentionDays, &textRetentionDays)
        d(.segmentRetentionDays, &segmentRetentionDays); d(.minLearningDays, &minLearningDays); d(.minLearningHours, &minLearningHours)
        d(.learningIdleMinutes, &learningIdleMinutes); d(.learnOnlyOnPower, &learnOnlyOnPower); d(.embeddingModelID, &embeddingModelID)
        d(.llmBackend, &llmBackend); d(.llamaServerPath, &llamaServerPath); d(.llmModelFile, &llmModelFile)
        d(.openAIBaseURL, &openAIBaseURL); d(.openAIModel, &openAIModel); d(.maxLLMCallsPerRun, &maxLLMCallsPerRun)
        d(.interfaceLanguage, &interfaceLanguage); d(.strictness, &strictness); d(.nudgeStyle, &nudgeStyle)
        d(.throttlingEnabled, &throttlingEnabled); d(.maxThrottle, &maxThrottle); d(.dimOverlayEnabled, &dimOverlayEnabled)
        d(.neverThrottleBundleIDs, &neverThrottleBundleIDs); d(.alwaysAllowedClusterIDs, &alwaysAllowedClusterIDs)
        d(.askWhenUncertain, &askWhenUncertain); d(.breakMinutes, &breakMinutes); d(.maxBreaksPerDay, &maxBreaksPerDay)
        d(.morningPlanPrompt, &morningPlanPrompt); d(.emergencyHotkeyEnabled, &emergencyHotkeyEnabled)
        d(.launchAtLogin, &launchAtLogin); d(.onboardingCompleted, &onboardingCompleted)
    }
}

/// Thread-safe settings holder with change notification.
public final class SettingsStore {
    public static let didChange = Notification.Name("TimeFocusSettingsDidChange")
    private let defaults: UserDefaults
    private let key = "settings.v1"
    private let lock = NSLock()
    private var cached: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            cached = s
        } else {
            cached = AppSettings()
        }
    }

    public var current: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func update(_ change: (inout AppSettings) -> Void) {
        lock.lock()
        var s = cached
        change(&s)
        let changed = s != cached
        cached = s
        lock.unlock()
        guard changed else { return }
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
