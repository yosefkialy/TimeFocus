import Foundation
import FocusML

public typealias ContextID = Int64
public typealias ClusterID = Int64

/// Where a context's activity-type assignment came from (higher = more trusted).
public enum AssignmentSource: Int, Codable {
    case none = 0
    case autoCluster = 1   // unsupervised clustering
    case prototype = 2     // nearest-prototype match in embedding space
    case llm = 3           // local LLM zero-shot decision (idle time)
    case user = 4          // explicit user feedback — never overridden automatically
}

/// Lightweight context row used on the real-time path.
public struct ContextRecord: Equatable {
    public var id: ContextID
    public var key: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var host: String?
    public var urlPath: String?
    public var clusterID: ClusterID?
    public var clusterSource: AssignmentSource
    public var clusterConfidence: Double
    public var isPrivate: Bool
    public var textUpdatedAt: Date?
    public var totalSeconds: Double
    public var behavior: BehaviorStats

    public init(id: ContextID, key: String, bundleID: String, appName: String, title: String, host: String?, urlPath: String?,
                clusterID: ClusterID?, clusterSource: AssignmentSource, clusterConfidence: Double, isPrivate: Bool,
                textUpdatedAt: Date?, totalSeconds: Double, behavior: BehaviorStats) {
        self.id = id; self.key = key; self.bundleID = bundleID; self.appName = appName; self.title = title
        self.host = host; self.urlPath = urlPath; self.clusterID = clusterID; self.clusterSource = clusterSource
        self.clusterConfidence = clusterConfidence; self.isPrivate = isPrivate; self.textUpdatedAt = textUpdatedAt
        self.totalSeconds = totalSeconds; self.behavior = behavior
    }
}

/// Full context row for the learning pipeline.
public struct LearningContext {
    public var id: ContextID
    public var bundleID: String
    public var appName: String
    public var title: String
    public var host: String?
    public var urlPath: String?
    public var text: String?
    public var totalSeconds: Double
    public var behavior: BehaviorStats
    public var meanHour: Double?
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var description: String?
    public var descriptionCategory: String?
    public var descriptionTopic: String?
    public var descriptionEmbedding: [Float]?
    public var clusterID: ClusterID?
    public var clusterSource: AssignmentSource
    public var clusterConfidence: Double
    public var isPrivate: Bool
    public var lastSeen: Date

    public init(id: ContextID, bundleID: String, appName: String, title: String, host: String?, urlPath: String?, text: String?,
                totalSeconds: Double, behavior: BehaviorStats, meanHour: Double?, embedding: [Float]?, embeddingModel: String?,
                description: String?, descriptionCategory: String?, descriptionTopic: String?, descriptionEmbedding: [Float]?,
                clusterID: ClusterID?, clusterSource: AssignmentSource, clusterConfidence: Double, isPrivate: Bool, lastSeen: Date) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.title = title; self.host = host
        self.urlPath = urlPath; self.text = text; self.totalSeconds = totalSeconds; self.behavior = behavior
        self.meanHour = meanHour; self.embedding = embedding; self.embeddingModel = embeddingModel
        self.description = description; self.descriptionCategory = descriptionCategory; self.descriptionTopic = descriptionTopic
        self.descriptionEmbedding = descriptionEmbedding; self.clusterID = clusterID; self.clusterSource = clusterSource
        self.clusterConfidence = clusterConfidence; self.isPrivate = isPrivate; self.lastSeen = lastSeen
    }

    public var descriptor: ActivityDescriptor {
        ActivityDescriptor(bundleID: bundleID, appName: appName, title: title, host: host, urlPath: urlPath,
                           text: text, behavior: behavior, hourOfDay: meanHour)
    }
}

/// One window as the evidence view needs it: identity, the text read from the screen, the LLM's description and how
/// the window got its activity type.
public struct EvidenceRow {
    public var id: ContextID
    public var bundleID: String
    public var appName: String
    public var title: String
    public var host: String?
    public var urlPath: String?
    public var text: String?
    public var behavior: BehaviorStats
    /// Σ sin/cos of the hour of day, weighted by seconds (circular mean of when the window is used).
    public var hourSin: Double
    public var hourCos: Double
    public var activity: String?
    public var category: String?
    public var topic: String?
    public var clusterID: ClusterID?
    public var assignment: AssignmentSource
    public var confidence: Double
    /// How many windows the row's activity type has in all (the query returns only the heaviest ones).
    public var groupWindows: Int

    public var seconds: Double { behavior.seconds }

    public init(id: ContextID, bundleID: String, appName: String, title: String, host: String? = nil, urlPath: String? = nil,
                text: String? = nil, behavior: BehaviorStats, hourSin: Double = 0, hourCos: Double = 0, activity: String? = nil,
                category: String? = nil, topic: String? = nil, clusterID: ClusterID?, assignment: AssignmentSource = .autoCluster,
                confidence: Double = 0, groupWindows: Int = 0) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.title = title; self.host = host
        self.urlPath = urlPath; self.text = text; self.behavior = behavior; self.hourSin = hourSin; self.hourCos = hourCos
        self.activity = activity; self.category = category; self.topic = topic; self.clusterID = clusterID
        self.assignment = assignment; self.confidence = confidence; self.groupWindows = groupWindows
    }
}

public struct ActivityCluster: Identifiable, Equatable, Hashable {
    public var id: ClusterID
    public var name: String?
    public var autoName: String
    public var suggestedName: String?
    public var description: String?
    public var keywords: [String]
    public var topApps: [String]
    public var color: Int
    public var userNamed: Bool
    public var archived: Bool
    public var mergedInto: ClusterID?
    public var totalSeconds: Double
    public var isNew: Bool

    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let s = suggestedName, !s.isEmpty { return s }
        return autoName
    }

    public init(id: ClusterID, name: String? = nil, autoName: String, suggestedName: String? = nil, description: String? = nil,
                keywords: [String] = [], topApps: [String] = [], color: Int = 0, userNamed: Bool = false, archived: Bool = false,
                mergedInto: ClusterID? = nil, totalSeconds: Double = 0, isNew: Bool = false) {
        self.id = id; self.name = name; self.autoName = autoName; self.suggestedName = suggestedName
        self.description = description; self.keywords = keywords; self.topApps = topApps; self.color = color
        self.userNamed = userNamed; self.archived = archived; self.mergedInto = mergedInto
        self.totalSeconds = totalSeconds; self.isNew = isNew
    }
}

public enum FocusStateCode: Int, Codable {
    case none = 0        // no focus block active
    case onTrack = 1
    case offTrack = 2
    case uncertain = 3
    case neutral = 4     // idle, break, paused, private or own app
}

public struct SegmentRecord: Identifiable, Equatable {
    public var id: Int64
    public var contextID: ContextID
    public var start: Date
    public var end: Date
    public var activeSeconds: Double
    public var clusterID: ClusterID?
    public var confidence: Double
    public var focusState: FocusStateCode
    public var throttleMax: Double
    public var appName: String
    public var bundleID: String
    public var title: String
    public var host: String?
    public var contextClusterID: ClusterID?
}

/// One focus block of a day plan (minutes since local midnight, end exclusive).
public struct FocusBlock: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var startMinute: Int
    public var endMinute: Int
    public var clusterIDs: [ClusterID]
    public var note: String

    public init(id: UUID = UUID(), startMinute: Int, endMinute: Int, clusterIDs: [ClusterID], note: String = "") {
        self.id = id; self.startMinute = startMinute; self.endMinute = endMinute; self.clusterIDs = clusterIDs; self.note = note
    }

    public func contains(minute: Int) -> Bool { minute >= startMinute && minute < endMinute }
    public var durationMinutes: Int { max(0, endMinute - startMinute) }
}

public struct DayPlan: Codable, Equatable {
    public var day: String
    public var blocks: [FocusBlock]
    public init(day: String, blocks: [FocusBlock] = []) { self.day = day; self.blocks = blocks.sorted { $0.startMinute < $1.startMinute } }

    public func block(at date: Date) -> FocusBlock? {
        guard date.dayKey == day else { return nil }
        let m = date.minuteOfDay
        return blocks.first { $0.contains(minute: m) }
    }
}

public enum EpisodeOutcome: Int, Codable {
    case ongoing = 0, returned = 1, tookBreak = 2, blockEnded = 3, dismissed = 4, markedRelevant = 5
}

public struct DriftEpisode: Identifiable, Equatable {
    public var id: Int64
    public var start: Date
    public var end: Date
    public var contextID: ContextID?
    public var clusterID: ClusterID?
    public var maxLevel: Double
    public var nudges: Int
    public var outcome: EpisodeOutcome
}

public enum FeedbackKind: Int, Codable {
    case assign = 0           // "this window belongs to activity type X"
    case allowDuringFocus = 1 // "this is part of my focus" (context-level allow)
    case confirm = 2          // user confirmed the prediction
}

/// Colour palette indices for clusters (rendered by the UI).
public enum ClusterPalette {
    public static let count = 12
}
