import FocusCore
import FocusML
import Foundation

/// Developer tool: FocusSelfTest --evidence-report <supportDir>
/// Prints what the activity-types screen shows for every type: keywords by source, the LLM's descriptions and the
/// words of each window — to check keyword quality on real data (run it on a copy of the database).
enum EvidenceReport {
    static func run(dir: URL) throws {
        let store = try Store(url: AppPaths(support: dir).database)
        let t0 = Date()
        let rows = try store.evidenceRows(minSeconds: 10, perGroup: 60, excludingBundleIDs: [AppPaths.ownBundleID])
        let snap = ActivityEvidence.build(rows)
        print("\(rows.count) windows in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
        let names = Dictionary(uniqueKeysWithValues: try store.clusters().map { ($0.id, $0.displayName) })
        var groups = snap.clusters.values.sorted { ($0.clusterID ?? 0) < ($1.clusterID ?? 0) }
        if let u = snap.unassigned { groups.append(u) }
        for e in groups {
            let name = e.clusterID.map { names[$0] ?? "(archived \($0))" } ?? "unassigned"
            print("\n== \(name)  [\(e.windows.count) windows]")
            print("   text:    " + e.textTerms.map { "\($0.term)(\($0.windows))" }.joined(separator: " · "))
            print("   address: " + e.addressTerms.map { "\($0.term)(\($0.windows))" }.joined(separator: " · "))
            print("   model:   " + e.descriptions.map { "\($0.activity) [\($0.topic ?? "-")]" }.joined(separator: " | "))
            print("   cats:    " + e.categories.map { "\($0.category) \(Int($0.share * 100))%" }.joined(separator: ", ")
                  + String(format: "   keys/min %.0f scrolls/min %.0f media %.0f%%", e.behavior.keysPerMin, e.behavior.scrollsPerMin,
                           e.behavior.mediaFraction * 100) + (e.typicalHour.map { String(format: "   ~%02d:00", Int($0)) } ?? ""))
            print("   keywords: " + e.keywords.joined(separator: ", "))
            for w in e.windows.prefix(8) {
                let label = w.hasInformativeTitle ? String(w.title.prefix(50)) : "\(w.appName) (no informative title)"
                print("   - \(label) \(w.host ?? "") \(Int(w.seconds))s: " + w.terms.map(\.term).joined(separator: " · "))
            }
        }
    }
}
