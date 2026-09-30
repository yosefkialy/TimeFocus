import FocusCore
import FocusML
import Foundation

/// Developer tool: FocusSelfTest --cluster-report <supportDir>   (env: K=<k> or T=<threshold>, TAU, CW, AW)
/// Prints the dendrogram profile, cluster composition and dominant zero-shot categories, to tune clustering.
enum ClusterReport {
    static let catNames = ["dev", "study", "reading", "email", "chat", "meetings", "planning", "writing", "design", "data",
                           "finance", "shopping", "news", "social", "video", "music", "games", "system"]

    static func run(dir: URL) throws {
        let env = ProcessInfo.processInfo.environment
        let paths = AppPaths(support: dir)
        let store = try Store(url: paths.database)
        let contexts = try store.learningContexts(minSeconds: 10, limit: 3000).filter { $0.embedding != nil }
        guard let model = contexts.first?.embeddingModel else { print("no embedded contexts"); return }
        let anchors = store.codable("anchors.\(model).v1", as: [[Float]].self) ?? []
        let calib = CategoryAnchors.calibrate(contexts.map { $0.embedding! }, anchors: anchors)
        let tau = Float(env["TAU"] ?? "0.6") ?? 0.6
        print("contexts: \(contexts.count), model \(model), anchors \(anchors.count), tau \(tau)")
        let inputs = contexts.map { c in
            RepresentationInput(textEmbedding: c.embedding!, descriptionEmbedding: nil, bundleID: c.bundleID, host: c.host,
                                behavior: c.behavior,
                                categoryProfile: CategoryAnchors.profile(c.embedding!, anchors: anchors, calibration: calib, temperature: tau))
        }
        let weights = contexts.map { Float(max($0.totalSeconds, 1).squareRoot()) }
        var b = RepresentationBuilder()
        if let cw = env["CW"].flatMap(Float.init) { b.categoryWeight = cw }
        if let aw = env["AW"].flatMap(Float.init) { b.appWeight = aw }
        b.fit(inputs, weights: weights)
        let reps = inputs.map { b.represent($0) }
        let n = reps.count
        var dist = LA.gram(LA.flatten(reps), rows: n, cols: reps[0].count).map { max(0, 1 - $0) }
        for i in 0..<n { dist[i * n + i] = 0 }
        var scratch = dist
        let merges = Agglomerative.linkage(distances: &scratch, n: n, weights: weights)
        print("last merge heights (k=16→1): " + merges.suffix(15).map { String(format: "%.3f", $0.distance) }.joined(separator: " "))
        var labels: [Int]
        if env["AUTO"] != nil {
            let dup = Float(env["DUP"] ?? "0.9") ?? 0.9
            let r = AutoCluster.run(vectors: reps, weights: weights, kRange: 3...10, duplicateThreshold: dup)
            let groups = AutoCluster.collapseNearDuplicates(reps, weights: weights, threshold: dup).reps.count
            print("auto: \(groups) distinct groups after collapsing near-duplicates (≥\(dup)) → k=\(r.k), silhouette \(r.silhouette)")
            labels = r.labels
        } else if let t = env["T"].flatMap(Float.init) {
            labels = Agglomerative.cut(merges, n: n, threshold: t)
        } else {
            labels = Agglomerative.cut(merges, n: n, k: Int(env["K"] ?? "8") ?? 8)
        }
        let k = (labels.max() ?? 0) + 1
        let sil = ClusterQuality.silhouette(distances: dist, n: n, labels: labels, weights: weights)
        print(String(format: "k=%d silhouette %.3f", k, sil))
        let cents = AutoCluster.centroids(vectors: reps, weights: weights, labels: labels, k: k)
        for l in 0..<k {
            let members = labels.indices.filter { labels[$0] == l }
            var prof = [Float](repeating: 0, count: anchors.count)
            for m in members { if let p = inputs[m].categoryProfile { LA.axpy(&prof, p, weights[m]) } }
            let total = prof.reduce(0, +)
            let top = prof.indices.sorted { prof[$0] > prof[$1] }.prefix(2)
            let cat = top.map { "\(catNames[$0]) \(Int(100 * prof[$0] / max(total, 1e-6)))%" }.joined(separator: ", ")
            let titles = Array(Set(members.map { String(contexts[$0].title.prefix(34)) })).sorted().prefix(4).joined(separator: " | ")
            let nearest = (0..<k).filter { $0 != l }.map { ($0, LA.dot(cents[l], cents[$0])) }.max { $0.1 < $1.1 }
            print(String(format: "[%2d] n=%3d  %@  nearest=%d(%.2f)  %@", l, members.count, cat, nearest?.0 ?? -1, nearest?.1 ?? 0, titles))
        }
        // per-context dominant category (first 30) to eyeball the zero-shot layer
        if env["CTX"] != nil {
            for (i, c) in contexts.enumerated().prefix(40) {
                if let p = inputs[i].categoryProfile, let j = p.indices.max(by: { p[$0] < p[$1] }) {
                    print(String(format: "  %-8@ %3d%%  %@", catNames[j], Int(p[j] * 100), String(c.title.prefix(60))))
                }
            }
        }
    }
}
