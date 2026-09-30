import Foundation

/// Multi-prototype nearest-class index in an embedding space.
/// Every activity type keeps several prototypes (sub-centroids), so a type like "Work" can cover several
/// distinct projects and keep growing as new members are added — this is how the system follows concept drift.
public struct PrototypeIndex: Codable {
    public var classIDs: [Int64]
    public var prototypes: [[Float]]
    public var owner: [Int]
    /// Per-class similarity below which a match is considered "novel" (5th percentile of member→prototype similarity).
    public var thresholds: [Float]

    public init(classIDs: [Int64] = [], prototypes: [[Float]] = [], owner: [Int] = [], thresholds: [Float] = []) {
        self.classIDs = classIDs; self.prototypes = prototypes; self.owner = owner; self.thresholds = thresholds
    }

    public var isEmpty: Bool { prototypes.isEmpty }
    public var dimension: Int { prototypes.first?.count ?? 0 }

    /// Builds prototypes for each class with weighted spherical k-means over its members.
    public static func build(vectors: [[Float]], weights: [Float], labels: [Int], classIDs: [Int64],
                             maxPrototypesPerClass: Int = 6, seed: UInt64 = 3) -> PrototypeIndex {
        var index = PrototypeIndex(classIDs: classIDs)
        index.thresholds = [Float](repeating: 0.3, count: classIDs.count)
        for c in 0..<classIDs.count {
            let members = labels.indices.filter { labels[$0] == c }
            guard !members.isEmpty else { continue }
            let vs = members.map { vectors[$0] }
            let ws = members.map { weights[$0] }
            let k = max(1, min(maxPrototypesPerClass, Int((Double(members.count) / 4).rounded(.up))))
            let (cents, _) = SphericalKMeans.run(vectors: vs, weights: ws, k: k, seed: seed &+ UInt64(c))
            for p in cents { index.prototypes.append(p); index.owner.append(c) }
            // similarity of members to their closest own prototype → robust novelty threshold
            var sims = vs.map { v in cents.map { LA.dot(v, $0) }.max() ?? 0 }
            sims.sort()
            let p5 = sims[min(sims.count - 1, Int(Float(sims.count) * 0.05))]
            index.thresholds[c] = max(0.15, min(0.8, p5 - 0.05))
        }
        return index
    }

    /// Best similarity per class (−1 for classes without prototypes).
    public func classSimilarities(_ v: [Float]) -> [Float] {
        var best = [Float](repeating: -1, count: classIDs.count)
        guard v.count == dimension else { return best }
        for (i, p) in prototypes.enumerated() {
            let s = LA.dot(v, p)
            if s > best[owner[i]] { best[owner[i]] = s }
        }
        return best
    }

    public struct Match {
        public var classIndex: Int
        public var similarity: Float
        public var margin: Float
        public var isNovel: Bool
    }

    public func bestMatch(_ v: [Float]) -> Match? {
        let sims = classSimilarities(v)
        guard let best = sims.indices.max(by: { sims[$0] < sims[$1] }), sims[best] > -1 else { return nil }
        let second = sims.enumerated().filter { $0.offset != best }.map(\.element).max() ?? -1
        return Match(classIndex: best, similarity: sims[best], margin: sims[best] - second,
                     isNovel: sims[best] < thresholds[best])
    }
}

/// Hidden-Markov-style forward filter over activity types: activity is "sticky" in time, so a single ambiguous
/// window does not flip the classification, while an app/tab switch weakens the prior so real changes are fast.
public struct TemporalSmoother {
    public private(set) var posterior: [Float]? = nil
    public var stayProbabilitySameContext: Float = 0.92
    public var stayProbabilityNewContext: Float = 0.55

    public init() {}

    public mutating func reset() { posterior = nil }

    /// - Parameter likelihood: per-class probability from the models (sums to ~1).
    public mutating func update(likelihood: [Float], contextChanged: Bool) -> [Float] {
        guard !likelihood.isEmpty else { return [] }
        guard let prev = posterior, prev.count == likelihood.count else {
            posterior = normalized(likelihood)
            return posterior!
        }
        let stay = contextChanged ? stayProbabilityNewContext : stayProbabilitySameContext
        let k = Float(likelihood.count)
        var post = [Float](repeating: 0, count: likelihood.count)
        for i in 0..<likelihood.count {
            let prior = stay * prev[i] + (1 - stay) / k
            post[i] = prior * max(likelihood[i], 1e-6)
        }
        posterior = normalized(post)
        return posterior!
    }

    private func normalized(_ x: [Float]) -> [Float] {
        let s = x.reduce(0, +)
        return s > 0 ? x.map { $0 / s } : x
    }
}

/// Class-based TF-IDF ("c-TF-IDF") keywords per cluster, used to describe clusters to the user.
public enum KeywordExtractor {
    /// - Parameter clusters: per cluster, the (weighted) frequency of each term.
    /// - Returns: per cluster, term → share of the term in the cluster × log(1 + average cluster size / the term's
    ///   frequency in all clusters). High for terms that are frequent in one cluster and rare in the others.
    public static func scores(_ clusters: [[String: Float]]) -> [[String: Float]] {
        var freq: [String: Float] = [:]
        var total: Float = 0
        for m in clusters { for (t, v) in m { freq[t, default: 0] += v; total += v } }
        let avg = total / Float(max(clusters.count, 1))
        return clusters.map { m in
            let size = max(m.values.reduce(0, +), 1e-6)
            var out: [String: Float] = [:]
            for (t, v) in m { out[t] = v / size * log(1 + avg / max(freq[t] ?? v, 1e-6)) }
            return out
        }
    }
}
