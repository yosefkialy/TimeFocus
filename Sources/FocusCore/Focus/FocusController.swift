import Foundation

public enum FocusVerdict: String, Codable {
    case noPlan, onTrack, offTrack, uncertain, neutral

    public var stateCode: FocusStateCode {
        switch self {
        case .noPlan: return .none
        case .onTrack: return .onTrack
        case .offTrack: return .offTrack
        case .uncertain: return .uncertain
        case .neutral: return .neutral
        }
    }
}

/// The focus that applies right now (from the day plan or a manual "focus now" session).
public struct ActiveFocus: Equatable {
    public var clusterIDs: Set<ClusterID>
    public var start: Date
    public var end: Date
    public var note: String
    public var isManual: Bool
    public var blockID: UUID?

    public init(clusterIDs: Set<ClusterID>, start: Date, end: Date, note: String = "", isManual: Bool, blockID: UUID? = nil) {
        self.clusterIDs = clusterIDs; self.start = start; self.end = end; self.note = note; self.isManual = isManual; self.blockID = blockID
    }
}

public struct FocusInput {
    public var now: Date
    public var focus: ActiveFocus?
    public var classification: Classification
    public var contextID: ContextID
    public var isPrivate: Bool
    public var isOwnApp: Bool
    public var contextAllowed: Bool
    public var contextDenied: Bool
    public var alwaysAllowed: Set<ClusterID>

    public init(now: Date, focus: ActiveFocus?, classification: Classification, contextID: ContextID, isPrivate: Bool,
                isOwnApp: Bool, contextAllowed: Bool, contextDenied: Bool, alwaysAllowed: Set<ClusterID>) {
        self.now = now; self.focus = focus; self.classification = classification; self.contextID = contextID
        self.isPrivate = isPrivate; self.isOwnApp = isOwnApp; self.contextAllowed = contextAllowed
        self.contextDenied = contextDenied; self.alwaysAllowed = alwaysAllowed
    }
}

public struct FocusOutput: Equatable {
    public var verdict: FocusVerdict
    public var neutralReason: String?
    public var throttleLevel: Double
    public var nudge: Bool
    public var isRepeatNudge: Bool
    public var ask: Bool
    public var driftSeconds: Double
    public var episodeStarted: Bool
    public var episodeEnded: EpisodeOutcome?
    /// Final values of an episode that just ended (captured before the controller resets them).
    public var endedEpisode: EpisodeSummary?
}

public struct EpisodeSummary: Equatable {
    public var nudges: Int
    public var maxLevel: Double
    /// Last moment the user was actually off track (the episode end, excluding any away time after it).
    public var lastOffTrack: Date?
}

/// Escalation state machine for one day: on-track → (grace) → reminder → gradual slowdown, released instantly on return.
/// Uncertain / unfamiliar activity is never punished — the user is asked instead (active learning).
public final class FocusController {
    public var settings: AppSettings
    public private(set) var driftSince: Date?
    public private(set) var level: Double = 0
    public private(set) var nudgesThisEpisode = 0
    public private(set) var maxLevelThisEpisode: Double = 0
    public private(set) var breakUntil: Date?
    public private(set) var breaksToday = 0
    /// Seconds actually spent off track in the current episode. Only consecutive off-track ticks count, so time
    /// away from the Mac (locked, idle), in uncertain/neutral windows or in TimeFocus itself never inflates it.
    public private(set) var offTrackSeconds: Double = 0
    public private(set) var lastOffTrackAt: Date?
    private var lastEvalWasOffTrack = false
    private var lastNudge: Date?
    private var uncertainSince: Date?
    private var uncertainContext: ContextID?
    private var askedContexts = Set<ContextID>()
    private var day = ""

    public init(settings: AppSettings) { self.settings = settings }

    public var breaksLeft: Int { max(0, settings.maxBreaksPerDay - breaksToday) }

    private func rollDay(_ now: Date) {
        let d = now.dayKey
        if d != day { day = d; breaksToday = 0; askedContexts.removeAll() }
    }

    /// Starts a short break (limited per day). Returns false when no breaks are left.
    @discardableResult
    public func startBreak(now: Date, minutes: Double? = nil) -> Bool {
        rollDay(now)
        guard breaksToday < settings.maxBreaksPerDay else { return false }
        breaksToday += 1
        breakUntil = now.addingTimeInterval((minutes ?? settings.breakMinutes) * 60)
        return true
    }

    public func endBreak() { breakUntil = nil }

    /// Clears drift state (e.g. emergency stop, focus finished). The caller closes any open episode first
    /// (see `episodeSummary`).
    public func reset() {
        driftSince = nil
        level = 0
        nudgesThisEpisode = 0
        maxLevelThisEpisode = 0
        offTrackSeconds = 0
        lastOffTrackAt = nil
        lastEvalWasOffTrack = false
        lastNudge = nil
        uncertainSince = nil
    }

    public var hasOpenEpisode: Bool { driftSince != nil }

    public var episodeSummary: EpisodeSummary {
        EpisodeSummary(nudges: nudgesThisEpisode, maxLevel: maxLevelThisEpisode, lastOffTrack: lastOffTrackAt)
    }

    /// The user left the Mac (screen locked / idle): pause the drift clock without ending the episode.
    public func noteAway() {
        lastEvalWasOffTrack = false
        level = 0
    }

    public func evaluate(_ input: FocusInput) -> FocusOutput {
        rollDay(input.now)
        let now = input.now
        var out = FocusOutput(verdict: .noPlan, neutralReason: nil, throttleLevel: 0, nudge: false, isRepeatNudge: false,
                              ask: false, driftSeconds: 0, episodeStarted: false, episodeEnded: nil, endedEpisode: nil)
        func endEpisode(_ outcome: EpisodeOutcome) {
            if driftSince != nil {
                out.episodeEnded = outcome
                out.endedEpisode = episodeSummary
            }
            reset()
        }
        let wasOffTrack = lastEvalWasOffTrack
        lastEvalWasOffTrack = false // set again below only for an off-track verdict

        guard let focus = input.focus, now >= focus.start, now < focus.end else {
            endEpisode(.blockEnded)
            return out
        }
        if let b = breakUntil {
            if b > now {
                endEpisode(.tookBreak)
                out.verdict = .neutral
                out.neutralReason = "break"
                return out
            }
            breakUntil = nil
        }
        if input.isOwnApp || input.isPrivate {
            // never act on our own window or private/excluded apps; keep the episode open
            level = 0
            out.verdict = .neutral
            out.neutralReason = input.isOwnApp ? "self" : "private"
            out.driftSeconds = offTrackSeconds
            return out
        }

        let profile = settings.strictness.profile
        let allowed = focus.clusterIDs.union(input.alwaysAllowed)
        let c = input.classification
        let pOn = c.distribution.filter { allowed.contains($0.key) }.reduce(0) { $0 + $1.value }
        var verdict: FocusVerdict
        if input.contextDenied {
            verdict = .offTrack
        } else if input.contextAllowed {
            verdict = .onTrack
        } else if c.source == .none {
            verdict = .uncertain
        } else if c.source == .model && c.novelty > 0.65 {
            verdict = .uncertain
        } else if pOn >= 0.5 {
            verdict = .onTrack
        } else if 1 - pOn >= profile.offTrackThreshold {
            verdict = .offTrack
        } else {
            verdict = .uncertain
        }
        out.verdict = verdict

        switch verdict {
        case .onTrack:
            endEpisode(.returned)
            uncertainSince = nil
        case .offTrack:
            uncertainSince = nil
            if driftSince == nil {
                driftSince = now
                out.episodeStarted = true
            }
            // accumulate only the time between consecutive off-track observations (capped per tick)
            if wasOffTrack, let last = lastOffTrackAt { offTrackSeconds += min(max(0, now.timeIntervalSince(last)), 12) }
            lastOffTrackAt = now
            lastEvalWasOffTrack = true
            let elapsed = offTrackSeconds
            out.driftSeconds = elapsed
            if settings.nudgeStyle != .none, elapsed >= profile.nudgeAfter,
               lastNudge == nil || now.timeIntervalSince(lastNudge!) >= profile.renudgeEvery {
                out.nudge = true
                out.isRepeatNudge = lastNudge != nil
                lastNudge = now
                nudgesThisEpisode += 1
            }
            if settings.throttlingEnabled, elapsed >= profile.throttleAfter {
                let ramp = min(1, 0.12 + 0.88 * (elapsed - profile.throttleAfter) / max(profile.rampSeconds, 1))
                level = settings.maxThrottle * ramp
            } else {
                level = 0
            }
            maxLevelThisEpisode = max(maxLevelThisEpisode, level)
            out.throttleLevel = level
        case .uncertain:
            // do not punish the unknown: release the slowdown but remember that a drift may be in progress
            level = 0
            out.driftSeconds = offTrackSeconds
            if uncertainContext != input.contextID { uncertainContext = input.contextID; uncertainSince = now }
            if settings.askWhenUncertain, c.source != .assigned, !askedContexts.contains(input.contextID),
               let since = uncertainSince, now.timeIntervalSince(since) >= 45 {
                askedContexts.insert(input.contextID)
                out.ask = true
            }
        case .noPlan, .neutral:
            break
        }
        return out
    }
}
