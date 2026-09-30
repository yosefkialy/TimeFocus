import Foundation
import FocusML

public struct Classification: Equatable {
    public enum Source: String { case none, assigned, model }
    public var clusterID: ClusterID?
    public var confidence: Double
    /// 0 = looks exactly like known activity, 1 = never seen anything like it.
    public var novelty: Double
    public var distribution: [ClusterID: Double]
    public var source: Source

    public init(clusterID: ClusterID?, confidence: Double, novelty: Double, distribution: [ClusterID: Double], source: Source) {
        self.clusterID = clusterID; self.confidence = confidence; self.novelty = novelty
        self.distribution = distribution; self.source = source
    }

    public static let none = Classification(clusterID: nil, confidence: 0, novelty: 1, distribution: [:], source: .none)
}

/// Real-time activity-type classification (runs every tick on the tracking queue, < 1 ms):
///   1. contexts already explained by the idle-time pipeline (or by the user) use that assignment;
///   2. otherwise the student network (hashed text/app/site/behaviour features) and the multi-prototype index
///      (on the student's distilled semantic embedding) vote as a product of experts;
///   3. an HMM-style temporal filter smooths the result across ticks.
public final class RealtimeClassifier {
    private var bundle: ModelBundle?
    private var clusterIDs: [ClusterID] = []
    private var redirect: [ClusterID: ClusterID] = [:]
    private var smoother = TemporalSmoother()
    private let featurizer = ActivityFeaturizer()
    private var lastContext: ContextID?

    public init() {}

    public var hasModel: Bool { !(bundle?.clusters.isEmpty ?? true) }
    public var bundleVersion: Int { bundle?.meta.version ?? 0 }

    /// Installs a new bundle and the current cluster list (merged clusters are redirected to their target).
    public func install(_ bundle: ModelBundle?, clusters allClusters: [ActivityCluster]) {
        self.bundle = bundle
        let active = allClusters.filter { !$0.archived }
        clusterIDs = active.map(\.id)
        redirect = [:]
        for c in allClusters where c.archived { if let t = c.mergedInto { redirect[c.id] = t } }
        smoother.reset()
    }

    private func resolve(_ id: ClusterID?) -> ClusterID? {
        guard var id else { return nil }
        var hops = 0
        while let next = redirect[id], hops < 8 { id = next; hops += 1 }
        return clusterIDs.contains(id) ? id : nil
    }

    public func classify(context: ContextRecord, text: String?, now: Date) -> Classification {
        guard !clusterIDs.isEmpty else { return .none }
        let changed = context.id != lastContext
        lastContext = context.id
        let k = clusterIDs.count
        var likelihood = [Double](repeating: 1.0 / Double(k), count: k)
        var novelty = 1.0
        var source = Classification.Source.none

        if let assigned = resolve(context.clusterID), let idx = clusterIDs.firstIndex(of: assigned),
           context.clusterSource != .none {
            let trust: Double
            switch context.clusterSource {
            case .user: trust = 0.97
            case .llm: trust = 0.85
            case .prototype, .autoCluster: trust = 0.75 + 0.2 * min(1, max(0, context.clusterConfidence))
            case .none: trust = 0.5
            }
            likelihood = (0..<k).map { $0 == idx ? trust : (1 - trust) / Double(max(k - 1, 1)) }
            novelty = 0
            source = .assigned
        } else if let bundle {
            let descriptor = ActivityDescriptor(bundleID: context.bundleID, appName: context.appName, title: context.title,
                                                host: context.host, urlPath: context.urlPath, text: text,
                                                behavior: context.behavior, hourOfDay: now.hourOfDayFraction)
            var experts: [[Double]] = []
            var semantic: [Float]? = nil
            if let student = bundle.student {
                let pred = student.predict(featurizer.featurize(descriptor),
                                           behaviorConfidence: Float(min(1, context.behavior.seconds / 90)))
                semantic = pred.semantic
                if !pred.probabilities.isEmpty {
                    var p = [Double](repeating: 1e-4, count: k)
                    for (i, cid) in student.classIDs.enumerated() {
                        if let target = resolve(cid), let j = clusterIDs.firstIndex(of: target) { p[j] += Double(pred.probabilities[i]) }
                    }
                    experts.append(p)
                }
            }
            if let sem = semantic, !bundle.meta.prototypes.isEmpty, bundle.meta.representation.isFitted {
                let profile = bundle.meta.anchors.flatMap {
                    CategoryAnchors.profile(sem, anchors: $0, calibration: bundle.meta.anchorCalibration)
                }
                let rep = bundle.meta.representation.represent(RepresentationInput(
                    textEmbedding: sem, descriptionEmbedding: nil, bundleID: context.bundleID, host: context.host,
                    behavior: context.behavior, categoryProfile: profile,
                    behaviorConfidence: Float(min(1, context.behavior.seconds / 90))))
                let sims = bundle.meta.prototypes.classSimilarities(rep)
                var p = [Double](repeating: 1e-4, count: k)
                var best: (sim: Float, cls: Int)? = nil
                for (i, cid) in bundle.meta.prototypes.classIDs.enumerated() {
                    guard let target = resolve(cid), let j = clusterIDs.firstIndex(of: target), sims[i] > -1 else { continue }
                    p[j] = max(p[j], Double(exp((sims[i] - 1) / 0.06)))
                    if best == nil || sims[i] > best!.sim { best = (sims[i], i) }
                }
                experts.append(p)
                if let b = best {
                    let thr = bundle.meta.prototypes.thresholds[b.cls]
                    novelty = 1 / (1 + exp(-Double((thr - b.sim) / 0.04)))
                }
            } else if let first = experts.first {
                // no semantic head: use normalised entropy as novelty
                let s = first.reduce(0, +)
                let h = -first.map { $0 / s }.filter { $0 > 0 }.reduce(0) { $0 + $1 * log($1) }
                novelty = h / log(Double(max(k, 2)))
            }
            if !experts.isEmpty {
                // product of experts (geometric mean)
                likelihood = (0..<k).map { j in exp(experts.reduce(0) { $0 + log(max($1[j], 1e-9)) } / Double(experts.count)) }
                let s = likelihood.reduce(0, +)
                likelihood = likelihood.map { $0 / s }
                source = .model
            }
        }

        let post = smoother.update(likelihood: likelihood.map { Float($0) }, contextChanged: changed).map { Double($0) }
        guard let best = post.indices.max(by: { post[$0] < post[$1] }) else { return .none }
        var dist: [ClusterID: Double] = [:]
        for (i, cid) in clusterIDs.enumerated() { dist[cid] = post[i] }
        return Classification(clusterID: source == .none ? nil : clusterIDs[best], confidence: post[best],
                              novelty: novelty, distribution: dist, source: source)
    }
}
