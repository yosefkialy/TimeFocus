import Accelerate
import Foundation

/// One merge step of a dendrogram: clusters represented by points `a` and `b` joined at `distance`.
public struct Merge: Equatable {
    public var a: Int
    public var b: Int
    public var distance: Float
}

/// Weighted average-linkage (UPGMA) agglomerative clustering using the nearest-neighbour-chain algorithm.
/// O(n²) time and memory — fine for a few thousand activity contexts at idle time.
public enum Agglomerative {
    /// - Parameters:
    ///   - distances: full n×n symmetric distance matrix (row-major). Consumed as scratch space.
    ///   - weights: point weights (e.g. √time); cluster size in the Lance–Williams update is the weight sum.
    /// - Returns: n-1 merges sorted by increasing distance.
    public static func linkage(distances D: inout [Float], n: Int, weights: [Float]) -> [Merge] {
        guard n > 1 else { return [] }
        var size = weights.map { max($0, 1e-6) }
        var active = [Bool](repeating: true, count: n)
        var activeList = Array(0..<n)
        var activePos = Array(0..<n)
        var merges: [Merge] = []
        merges.reserveCapacity(n - 1)
        var chain: [Int] = []

        func removeActive(_ x: Int) {
            let p = activePos[x]
            let last = activeList.removeLast()
            if last != x { activeList[p] = last; activePos[last] = p }
            active[x] = false
        }

        D.withUnsafeMutableBufferPointer { dist in
            while activeList.count > 1 {
                if chain.isEmpty { chain.append(activeList[0]) }
                let a = chain[chain.count - 1]
                let prev = chain.count >= 2 ? chain[chain.count - 2] : -1
                // nearest active neighbour of a (prefer the previous chain element on ties)
                var best = prev
                var bestD: Float = prev >= 0 ? dist[a * n + prev] : .infinity
                let rowA = a * n
                for x in activeList where x != a {
                    let d = dist[rowA + x]
                    if d < bestD { bestD = d; best = x }
                }
                if best == prev {
                    chain.removeLast(2)
                    // merge prev into a (a keeps representing the union)
                    let b = prev
                    merges.append(Merge(a: a, b: b, distance: bestD))
                    let sa = size[a], sb = size[b], s = sa + sb
                    for x in activeList where x != a && x != b {
                        let nd = (sa * dist[a * n + x] + sb * dist[b * n + x]) / s
                        dist[a * n + x] = nd
                        dist[x * n + a] = nd
                    }
                    size[a] = s
                    removeActive(b)
                } else {
                    chain.append(best)
                }
            }
        }
        merges.sort { $0.distance < $1.distance }
        return merges
    }

    /// Applies the first `n - k` merges and returns compact labels 0..<k.
    public static func cut(_ merges: [Merge], n: Int, k: Int) -> [Int] {
        let steps = max(0, min(merges.count, n - max(k, 1)))
        return labels(from: Array(merges.prefix(steps)), n: n)
    }

    /// Applies all merges below `threshold`.
    public static func cut(_ merges: [Merge], n: Int, threshold: Float) -> [Int] {
        labels(from: merges.filter { $0.distance <= threshold }, n: n)
    }

    static func labels(from merges: [Merge], n: Int) -> [Int] {
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for m in merges {
            let ra = find(m.a), rb = find(m.b)
            if ra != rb { parent[rb] = ra }
        }
        var map: [Int: Int] = [:]
        return (0..<n).map { i in
            let r = find(i)
            if let l = map[r] { return l }
            let l = map.count
            map[r] = l
            return l
        }
    }
}

public enum ClusterQuality {
    /// Weighted mean silhouette coefficient in [-1, 1] for a precomputed distance matrix.
    public static func silhouette(distances D: [Float], n: Int, labels: [Int], weights: [Float]) -> Float {
        let k = (labels.max() ?? 0) + 1
        guard k >= 2, n > k else { return -1 }
        var clusterWeight = [Float](repeating: 0, count: k)
        for i in 0..<n { clusterWeight[labels[i]] += weights[i] }
        var total: Float = 0, wsum: Float = 0
        var sums = [Float](repeating: 0, count: k)
        D.withUnsafeBufferPointer { d in
            for i in 0..<n {
                for c in 0..<k { sums[c] = 0 }
                let row = i * n
                for j in 0..<n where j != i { sums[labels[j]] += weights[j] * d[row + j] }
                let own = labels[i]
                let ownW = clusterWeight[own] - weights[i]
                guard ownW > 1e-9 else { continue } // singleton: silhouette 0 by convention (skip)
                let a = sums[own] / ownW
                var b = Float.infinity
                for c in 0..<k where c != own && clusterWeight[c] > 0 { b = min(b, sums[c] / clusterWeight[c]) }
                let s = (b - a) / max(a, b, 1e-9)
                total += weights[i] * s
                wsum += weights[i]
            }
        }
        return wsum > 0 ? total / wsum : -1
    }
}

public struct AutoClusterResult {
    public var labels: [Int]
    public var k: Int
    public var silhouette: Float
    public var centroids: [[Float]]
}

public enum AutoCluster {
    /// Greedy grouping of near-duplicate vectors (e.g. "Lecture 3" / "Lecture 4" of the same course page).
    /// Returns the group index of every vector and the weighted, normalised group representatives.
    public static func collapseNearDuplicates(_ vectors: [[Float]], weights: [Float], threshold: Float)
        -> (group: [Int], reps: [[Float]], weights: [Float]) {
        let order = vectors.indices.sorted { weights[$0] > weights[$1] }
        var group = [Int](repeating: -1, count: vectors.count)
        var reps: [[Float]] = [], sums: [[Float]] = [], gw: [Float] = []
        for i in order {
            var best = -1
            var bestSim = threshold
            for (g, r) in reps.enumerated() {
                let s = LA.dot(vectors[i], r)
                if s >= bestSim { bestSim = s; best = g }
            }
            if best >= 0 {
                group[i] = best
                LA.axpy(&sums[best], vectors[i], weights[i])
                gw[best] += weights[i]
            } else {
                group[i] = reps.count
                reps.append(vectors[i])
                sums.append(vectors[i].map { $0 * weights[i] })
                gw.append(weights[i])
            }
        }
        return (group, sums.map { LA.normalized($0) }, gw)
    }

    /// Clusters L2-normalised vectors (cosine distance, weighted average linkage). Near-duplicates are collapsed
    /// first so that the weighted silhouette measures separation between genuinely different activities (tight
    /// families of near-identical windows would otherwise always favour ever finer clusterings); the number of
    /// types is then chosen by silhouette within `kRange`, and types below `minShare` of the time are folded into
    /// their nearest neighbour.
    public static func run(vectors: [[Float]], weights: [Float], kRange: ClosedRange<Int> = 4...10,
                           minShare: Float = 0.015, duplicateThreshold: Float = 0.9) -> AutoClusterResult {
        let n0 = vectors.count
        guard n0 >= 2 else {
            return AutoClusterResult(labels: Array(repeating: 0, count: n0), k: n0, silhouette: 0, centroids: vectors)
        }
        let collapsed = collapseNearDuplicates(vectors, weights: weights, threshold: duplicateThreshold)
        let pts = collapsed.reps, pw = collapsed.weights
        let n = pts.count
        var groupLabels: [Int]
        var bestSil: Float = 0
        if n < 3 {
            groupLabels = Array(0..<n)
        } else {
            let flat = LA.flatten(pts)
            var dist = LA.gram(flat, rows: n, cols: pts[0].count)
            for i in 0..<(n * n) { dist[i] = max(0, 1 - dist[i]) }
            for i in 0..<n { dist[i * n + i] = 0 }
            var scratch = dist
            let merges = Agglomerative.linkage(distances: &scratch, n: n, weights: pw)
            scratch = []
            let lo = max(2, min(kRange.lowerBound, n - 1))
            let hi = max(lo, min(kRange.upperBound, n - 1))
            var bestScore = -Float.infinity
            groupLabels = Agglomerative.cut(merges, n: n, k: lo)
            for k in lo...hi {
                let labels = Agglomerative.cut(merges, n: n, k: k)
                let sil = ClusterQuality.silhouette(distances: dist, n: n, labels: labels, weights: pw)
                if sil > bestScore { bestScore = sil; bestSil = sil; groupLabels = labels }
            }
        }
        var labels = collapsed.group.map { groupLabels[$0] }
        labels = foldSmallClusters(labels: compact(labels), vectors: vectors, weights: weights, minShare: minShare)
        labels = relabelBySize(labels, weights: weights)
        let k = (labels.max() ?? -1) + 1
        let cents = centroids(vectors: vectors, weights: weights, labels: labels, k: k)
        return AutoClusterResult(labels: labels, k: k, silhouette: bestSil, centroids: cents)
    }

    public static func centroids(vectors: [[Float]], weights: [Float], labels: [Int], k: Int) -> [[Float]] {
        guard let d = vectors.first?.count else { return [] }
        var c = [[Float]](repeating: [Float](repeating: 0, count: d), count: k)
        for (i, v) in vectors.enumerated() where labels[i] >= 0 { LA.axpy(&c[labels[i]], v, weights[i]) }
        return c.map { LA.normalized($0) }
    }

    static func foldSmallClusters(labels: [Int], vectors: [[Float]], weights: [Float], minShare: Float) -> [Int] {
        var labels = labels
        let total = weights.reduce(0, +)
        while true {
            let k = (labels.max() ?? -1) + 1
            guard k > 2 else { return labels }
            var w = [Float](repeating: 0, count: k)
            for (i, l) in labels.enumerated() { w[l] += weights[i] }
            guard let smallest = w.indices.min(by: { w[$0] < w[$1] }), w[smallest] < minShare * total else { return labels }
            let cents = centroids(vectors: vectors, weights: weights, labels: labels, k: k)
            var best = -1
            var bestSim = -Float.infinity
            for c in 0..<k where c != smallest {
                let s = LA.dot(cents[smallest], cents[c])
                if s > bestSim { bestSim = s; best = c }
            }
            for i in labels.indices where labels[i] == smallest { labels[i] = best }
            labels = compact(labels)
        }
    }

    static func compact(_ labels: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        return labels.map { l in
            if let m = map[l] { return m }
            let m = map.count
            map[l] = m
            return m
        }
    }

    /// Label 0 = heaviest cluster.
    static func relabelBySize(_ labels: [Int], weights: [Float]) -> [Int] {
        let k = (labels.max() ?? -1) + 1
        var w = [Float](repeating: 0, count: k)
        for (i, l) in labels.enumerated() { w[l] += weights[i] }
        let order = (0..<k).sorted { w[$0] > w[$1] }
        var map = [Int](repeating: 0, count: k)
        for (newL, oldL) in order.enumerated() { map[oldL] = newL }
        return labels.map { map[$0] }
    }

    /// Assigns vectors to the nearest centroid (cosine). Returns label and similarity.
    public static func assign(_ v: [Float], centroids: [[Float]]) -> (label: Int, similarity: Float) {
        var best = -1
        var bestSim = -Float.infinity
        for (i, c) in centroids.enumerated() {
            let s = LA.dot(v, c)
            if s > bestSim { bestSim = s; best = i }
        }
        return (best, bestSim)
    }
}

/// Weighted spherical k-means with k-means++ seeding (used to derive per-cluster prototypes).
public enum SphericalKMeans {
    public static func run(vectors: [[Float]], weights: [Float], k: Int, iterations: Int = 25, seed: UInt64 = 1) -> (centroids: [[Float]], labels: [Int]) {
        let n = vectors.count
        guard n > 0 else { return ([], []) }
        let k = min(k, n)
        var rng = SeededRandom(seed: seed)
        var cents: [[Float]] = []
        // k-means++ seeding (weighted)
        let first = weightedPick(weights, &rng)
        cents.append(vectors[first])
        var minD = vectors.map { 1 - LA.dot($0, cents[0]) }
        while cents.count < k {
            let probs = zip(minD, weights).map { max($0, 0) * $1 }
            let idx = probs.reduce(0, +) > 0 ? weightedPick(probs, &rng) : Int(rng.next() % UInt64(n))
            cents.append(vectors[idx])
            for i in 0..<n { minD[i] = min(minD[i], 1 - LA.dot(vectors[i], cents.last!)) }
        }
        var labels = [Int](repeating: 0, count: n)
        for _ in 0..<iterations {
            var changed = false
            for i in 0..<n {
                let (l, _) = AutoCluster.assign(vectors[i], centroids: cents)
                if l != labels[i] { labels[i] = l; changed = true }
            }
            var newC = [[Float]](repeating: [Float](repeating: 0, count: vectors[0].count), count: k)
            var counts = [Float](repeating: 0, count: k)
            for i in 0..<n { LA.axpy(&newC[labels[i]], vectors[i], weights[i]); counts[labels[i]] += weights[i] }
            for c in 0..<k { cents[c] = counts[c] > 0 ? LA.normalized(newC[c]) : cents[c] }
            if !changed { break }
        }
        return (cents, labels)
    }

    static func weightedPick(_ w: [Float], _ rng: inout SeededRandom) -> Int {
        let total = w.reduce(0, +)
        guard total > 0 else { return 0 }
        var r = rng.uniform() * total
        for (i, x) in w.enumerated() { r -= x; if r <= 0 { return i } }
        return w.count - 1
    }
}
