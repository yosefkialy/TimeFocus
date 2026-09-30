import Foundation
import FocusML

/// Everything the real-time classifier needs, produced by the idle-time learning pipeline and swapped in atomically.
public struct BundleMeta: Codable {
    public var version: Int
    public var embeddingModel: String
    public var semanticDim: Int
    public var prototypes: PrototypeIndex
    public var representation: RepresentationBuilder
    public var builtAt: Date
    /// Zero-shot category anchor embeddings (teacher space), used to profile the student's semantic output.
    public var anchors: [[Float]]?
    public var anchorCalibration: CategoryAnchors.Calibration?
}

public final class ModelBundle {
    public let meta: BundleMeta
    public let student: StudentNetwork?
    public let clusters: [ActivityCluster]

    public init(meta: BundleMeta, student: StudentNetwork?, clusters: [ActivityCluster]) {
        self.meta = meta
        self.student = student
        self.clusters = clusters
    }

    static let metaKey = "bundle.meta.v1"

    public func save(store: Store, paths: AppPaths) {
        do {
            try store.setCodable(Self.metaKey, meta)
            if let s = student {
                let tmp = paths.studentModel.appendingPathExtension("tmp")
                try s.serialized().write(to: tmp, options: .atomic)
                _ = try? FileManager.default.replaceItemAt(paths.studentModel, withItemAt: tmp)
                if !FileManager.default.fileExists(atPath: paths.studentModel.path) {
                    try FileManager.default.moveItem(at: tmp, to: paths.studentModel)
                }
            }
        } catch {
            Log.error("saving model bundle failed: \(error)", "learning")
        }
    }

    public static func load(store: Store, paths: AppPaths) -> ModelBundle? {
        guard let meta = store.codable(metaKey, as: BundleMeta.self) else { return nil }
        let student = (try? Data(contentsOf: paths.studentModel)).flatMap { try? StudentNetwork(serialized: $0) }
        let clusters = (try? store.clusters()) ?? []
        return ModelBundle(meta: meta, student: student, clusters: clusters)
    }
}

/// Learning lifecycle: first collect data, then ask the user to (optionally) name the activity types, then run.
public enum LearningPhase: String, Codable {
    case collecting, naming, active
}

public struct LearningReadiness: Equatable {
    public var daysWithData: Int
    public var hoursTracked: Double
    public var requiredDays: Int
    public var requiredHours: Double
    public var clusterCount: Int
    public var isReady: Bool { daysWithData >= requiredDays && hoursTracked >= requiredHours && clusterCount >= 2 }
    public var fraction: Double {
        min(1, 0.5 * min(1, Double(daysWithData) / Double(max(requiredDays, 1))) + 0.5 * min(1, hoursTracked / max(requiredHours, 0.1)))
    }
}

public struct LearningStatus: Equatable {
    public init() {}

    public enum Stage: String {
        case idle, waitingForIdle, embedding, describing, clustering, naming, training, finished, cancelled, failed
    }
    public var stage: Stage = .idle
    public var detail: String = ""
    public var progress: Double = 0
    public var running = false
    public var lastRun: Date?
    public var lastRunSeconds: Double?
    public var lastOutcome: String?
    public var studentAccuracy: Float?
    public var studentSemanticCosine: Float?
    public var embeddingModel: String = ""
    public var llmName: String?
    public var llmNote: String?
    public var phase: LearningPhase = .collecting
    public var counts = Store.Counts()
    public var readiness = LearningReadiness(daysWithData: 0, hoursTracked: 0, requiredDays: 3, requiredHours: 6, clusterCount: 0)
    public var newClusters: [ClusterID] = []
}

/// Thread-safe cancellation flag polled by long-running learning stages.
public final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
