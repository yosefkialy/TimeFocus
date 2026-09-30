import Foundation
import FocusML

/// Typed data-access layer over the local SQLite database.
/// Create one `Store` per subsystem (tracking, learning, UI); each owns its own connection.
public final class Store {
    public let db: SQLiteDB
    public static let schemaVersion = 1

    public init(url: URL) throws {
        db = try SQLiteDB(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        try db.script("""
        CREATE TABLE IF NOT EXISTS contexts (
          id INTEGER PRIMARY KEY,
          key TEXT NOT NULL UNIQUE,
          bundle_id TEXT NOT NULL,
          app_name TEXT NOT NULL,
          title TEXT NOT NULL,
          host TEXT,
          url_path TEXT,
          doc_path TEXT,
          text TEXT,
          text_updated REAL,
          first_seen REAL NOT NULL,
          last_seen REAL NOT NULL,
          total_secs REAL NOT NULL DEFAULT 0,
          keys REAL NOT NULL DEFAULT 0,
          clicks REAL NOT NULL DEFAULT 0,
          scrolls REAL NOT NULL DEFAULT 0,
          moves REAL NOT NULL DEFAULT 0,
          media_secs REAL NOT NULL DEFAULT 0,
          hsin REAL NOT NULL DEFAULT 0,
          hcos REAL NOT NULL DEFAULT 0,
          emb BLOB,
          emb_model TEXT,
          emb_updated REAL,
          desc TEXT,
          desc_category TEXT,
          desc_topic TEXT,
          desc_model TEXT,
          desc_emb BLOB,
          desc_attempted REAL,
          cluster_id INTEGER,
          cluster_source INTEGER NOT NULL DEFAULT 0,
          cluster_conf REAL NOT NULL DEFAULT 0,
          cluster_updated REAL,
          private INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_ctx_last_seen ON contexts(last_seen);
        CREATE INDEX IF NOT EXISTS idx_ctx_cluster ON contexts(cluster_id);
        CREATE TABLE IF NOT EXISTS segments (
          id INTEGER PRIMARY KEY,
          context_id INTEGER NOT NULL,
          start_ts REAL NOT NULL,
          end_ts REAL NOT NULL,
          active_secs REAL NOT NULL DEFAULT 0,
          keys REAL NOT NULL DEFAULT 0,
          clicks REAL NOT NULL DEFAULT 0,
          scrolls REAL NOT NULL DEFAULT 0,
          moves REAL NOT NULL DEFAULT 0,
          media_secs REAL NOT NULL DEFAULT 0,
          cluster_id INTEGER,
          conf REAL NOT NULL DEFAULT 0,
          focus_state INTEGER NOT NULL DEFAULT 0,
          throttle_max REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_seg_start ON segments(start_ts);
        CREATE INDEX IF NOT EXISTS idx_seg_ctx ON segments(context_id);
        CREATE TABLE IF NOT EXISTS clusters (
          id INTEGER PRIMARY KEY,
          name TEXT,
          auto_name TEXT NOT NULL DEFAULT '',
          suggested_name TEXT,
          description TEXT,
          keywords TEXT,
          top_apps TEXT,
          color INTEGER NOT NULL DEFAULT 0,
          user_named INTEGER NOT NULL DEFAULT 0,
          archived INTEGER NOT NULL DEFAULT 0,
          merged_into INTEGER,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          total_secs REAL NOT NULL DEFAULT 0,
          is_new INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS feedback (
          id INTEGER PRIMARY KEY,
          ts REAL NOT NULL,
          context_id INTEGER NOT NULL,
          cluster_id INTEGER,
          kind INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS plans (day TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS episodes (
          id INTEGER PRIMARY KEY,
          start_ts REAL NOT NULL,
          end_ts REAL NOT NULL,
          context_id INTEGER,
          cluster_id INTEGER,
          max_level REAL NOT NULL DEFAULT 0,
          nudges INTEGER NOT NULL DEFAULT 0,
          outcome INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_ep_start ON episodes(start_ts);
        CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB);
        PRAGMA user_version = 1;
        """)
    }

    // MARK: - Contexts (real-time path)

    private static let contextColumns = "id, key, bundle_id, app_name, title, host, url_path, cluster_id, cluster_source, cluster_conf, private, text_updated, total_secs, keys, clicks, scrolls, moves, media_secs"

    private func mapContext(_ s: SQLStatement) -> ContextRecord {
        ContextRecord(id: s.int(0), key: s.text(1), bundleID: s.text(2), appName: s.text(3), title: s.text(4),
                      host: s.textOpt(5), urlPath: s.textOpt(6), clusterID: s.intOpt(7),
                      clusterSource: AssignmentSource(rawValue: Int(s.int(8))) ?? .none, clusterConfidence: s.double(9),
                      isPrivate: s.int(10) != 0, textUpdatedAt: s.doubleOpt(11).map { Date(timeIntervalSince1970: $0) },
                      totalSeconds: s.double(12),
                      behavior: BehaviorStats(seconds: s.double(12), keys: s.double(13), clicks: s.double(14),
                                              scrolls: s.double(15), moves: s.double(16), mediaSeconds: s.double(17)))
    }

    public func context(key: String) throws -> ContextRecord? {
        try db.query("SELECT \(Self.contextColumns) FROM contexts WHERE key = ?", [.text(key)], mapContext).first
    }

    public func context(id: ContextID) throws -> ContextRecord? {
        try db.query("SELECT \(Self.contextColumns) FROM contexts WHERE id = ?", [.int(id)], mapContext).first
    }

    public func insertContext(key: String, bundleID: String, appName: String, title: String, host: String?,
                              urlPath: String?, docPath: String?, isPrivate: Bool, now: Date) throws -> ContextRecord {
        try db.run("""
            INSERT OR IGNORE INTO contexts (key, bundle_id, app_name, title, host, url_path, doc_path, first_seen, last_seen, private)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, [.text(key), .text(bundleID), .text(appName), .text(title), .opt(host), .opt(urlPath), .opt(docPath),
                  .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970), .int(isPrivate ? 1 : 0)])
        guard let c = try context(key: key) else { throw SQLiteError(code: -1, message: "context insert failed") }
        return c
    }

    public func touchContext(id: ContextID, urlPath: String?, now: Date) throws {
        try db.run("UPDATE contexts SET last_seen = ?, url_path = COALESCE(?, url_path) WHERE id = ?",
                   [.double(now.timeIntervalSince1970), .opt(urlPath), .int(id)])
    }

    public func addContextActivity(id: ContextID, seconds: Double, keys: Double, clicks: Double, scrolls: Double,
                                   moves: Double, mediaSeconds: Double, at date: Date) throws {
        let h = date.hourOfDayFraction
        let hs = sin(2 * .pi * h / 24) * seconds, hc = cos(2 * .pi * h / 24) * seconds
        try db.run("""
            UPDATE contexts SET total_secs = total_secs + ?, keys = keys + ?, clicks = clicks + ?, scrolls = scrolls + ?,
              moves = moves + ?, media_secs = media_secs + ?, hsin = hsin + ?, hcos = hcos + ?, last_seen = ? WHERE id = ?
            """, [.double(seconds), .double(keys), .double(clicks), .double(scrolls), .double(moves), .double(mediaSeconds),
                  .double(hs), .double(hc), .double(date.timeIntervalSince1970), .int(id)])
    }

    /// Merges newly observed text into the context's text sample (unique lines, capped length).
    public func mergeContextText(id: ContextID, text newText: String, now: Date, maxChars: Int = 3000) throws {
        let existing = try db.query("SELECT text FROM contexts WHERE id = ?", [.int(id)]) { $0.textOpt(0) }.first ?? nil
        var lines: [String] = []
        var seen = Set<String>()
        for l in (newText + "\n" + (existing ?? "")).split(whereSeparator: \.isNewline) {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, seen.insert(t).inserted else { continue }
            lines.append(t)
        }
        var merged = ""
        for l in lines {
            if merged.count + l.count + 1 > maxChars { break }
            merged += merged.isEmpty ? l : "\n" + l
        }
        try db.run("UPDATE contexts SET text = ?, text_updated = ? WHERE id = ?",
                   [.text(merged), .double(now.timeIntervalSince1970), .int(id)])
    }

    // MARK: - Segments & episodes

    public func insertSegment(contextID: ContextID, start: Date, clusterID: ClusterID?, confidence: Double,
                              focusState: FocusStateCode) throws -> Int64 {
        try db.run("""
            INSERT INTO segments (context_id, start_ts, end_ts, cluster_id, conf, focus_state) VALUES (?,?,?,?,?,?)
            """, [.int(contextID), .double(start.timeIntervalSince1970), .double(start.timeIntervalSince1970),
                  .opt(clusterID), .double(confidence), .int(Int64(focusState.rawValue))])
        return db.lastInsertRowID
    }

    public func extendSegment(id: Int64, end: Date, activeSeconds: Double, keys: Double, clicks: Double, scrolls: Double,
                              moves: Double, mediaSeconds: Double, clusterID: ClusterID?, confidence: Double,
                              focusState: FocusStateCode, throttle: Double) throws {
        try db.run("""
            UPDATE segments SET end_ts = ?, active_secs = active_secs + ?, keys = keys + ?, clicks = clicks + ?,
              scrolls = scrolls + ?, moves = moves + ?, media_secs = media_secs + ?, cluster_id = ?, conf = ?,
              focus_state = ?, throttle_max = MAX(throttle_max, ?) WHERE id = ?
            """, [.double(end.timeIntervalSince1970), .double(activeSeconds), .double(keys), .double(clicks), .double(scrolls),
                  .double(moves), .double(mediaSeconds), .opt(clusterID), .double(confidence),
                  .int(Int64(focusState.rawValue)), .double(throttle), .int(id)])
    }

    public func segments(from: Date, to: Date) throws -> [SegmentRecord] {
        try db.query("""
            SELECT s.id, s.context_id, s.start_ts, s.end_ts, s.active_secs, s.cluster_id, s.conf, s.focus_state, s.throttle_max,
                   c.app_name, c.bundle_id, c.title, c.host, c.cluster_id
            FROM segments s JOIN contexts c ON c.id = s.context_id
            WHERE s.end_ts >= ? AND s.start_ts < ? ORDER BY s.start_ts
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { s in
            SegmentRecord(id: s.int(0), contextID: s.int(1), start: Date(timeIntervalSince1970: s.double(2)),
                          end: Date(timeIntervalSince1970: s.double(3)), activeSeconds: s.double(4), clusterID: s.intOpt(5),
                          confidence: s.double(6), focusState: FocusStateCode(rawValue: Int(s.int(7))) ?? .none,
                          throttleMax: s.double(8), appName: s.text(9), bundleID: s.text(10), title: s.text(11),
                          host: s.textOpt(12), contextClusterID: s.intOpt(13))
        }
    }

    /// Seconds per activity type in a time range (current context assignment wins over the real-time guess).
    public func clusterSeconds(from: Date, to: Date) throws -> [ClusterID?: Double] {
        var out: [ClusterID?: Double] = [:]
        let rows = try db.query("""
            SELECT COALESCE(c.cluster_id, s.cluster_id), SUM(s.active_secs) FROM segments s JOIN contexts c ON c.id = s.context_id
            WHERE s.start_ts >= ? AND s.start_ts < ? AND c.private = 0 GROUP BY 1
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { ($0.intOpt(0), $0.double(1)) }
        for (k, v) in rows { out[k, default: 0] += v }
        return out
    }

    public func focusStateSeconds(from: Date, to: Date) throws -> [FocusStateCode: Double] {
        var out: [FocusStateCode: Double] = [:]
        let rows = try db.query("""
            SELECT focus_state, SUM(active_secs) FROM segments WHERE start_ts >= ? AND start_ts < ? GROUP BY focus_state
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { ($0.int(0), $0.double(1)) }
        for (k, v) in rows { out[FocusStateCode(rawValue: Int(k)) ?? .none, default: 0] += v }
        return out
    }

    /// Active seconds per local day for the last `days` days (learning progress).
    public func activeSecondsPerDay(days: Int = 30) throws -> [(day: String, seconds: Double)] {
        let since = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return try db.query("""
            SELECT date(start_ts, 'unixepoch', 'localtime') AS d, SUM(active_secs) FROM segments WHERE start_ts >= ?
            GROUP BY d ORDER BY d
            """, [.double(since)]) { ($0.text(0), $0.double(1)) }
    }

    /// Direct switches between contexts (A → B within 2 minutes) since a date — the co-usage graph.
    public func transitions(since: Date) throws -> [(a: ContextID, b: ContextID, count: Int)] {
        try db.query("""
            SELECT prev_ctx, context_id, COUNT(*) FROM (
              SELECT context_id, start_ts, LAG(context_id) OVER (ORDER BY start_ts) AS prev_ctx,
                     LAG(end_ts) OVER (ORDER BY start_ts) AS prev_end
              FROM segments WHERE start_ts >= ?
            ) WHERE prev_ctx IS NOT NULL AND prev_ctx != context_id AND start_ts - prev_end < 120
            GROUP BY prev_ctx, context_id
            """, [.double(since.timeIntervalSince1970)]) { ($0.int(0), $0.int(1), Int($0.int(2))) }
    }

    public func insertEpisode(start: Date, contextID: ContextID?, clusterID: ClusterID?) throws -> Int64 {
        try db.run("INSERT INTO episodes (start_ts, end_ts, context_id, cluster_id) VALUES (?,?,?,?)",
                   [.double(start.timeIntervalSince1970), .double(start.timeIntervalSince1970), .opt(contextID), .opt(clusterID)])
        return db.lastInsertRowID
    }

    public func updateEpisode(id: Int64, end: Date, maxLevel: Double, nudges: Int, outcome: EpisodeOutcome) throws {
        try db.run("UPDATE episodes SET end_ts = ?, max_level = MAX(max_level, ?), nudges = ?, outcome = ? WHERE id = ?",
                   [.double(end.timeIntervalSince1970), .double(maxLevel), .int(Int64(nudges)), .int(Int64(outcome.rawValue)), .int(id)])
    }

    public func episodes(from: Date, to: Date) throws -> [DriftEpisode] {
        try db.query("""
            SELECT id, start_ts, end_ts, context_id, cluster_id, max_level, nudges, outcome FROM episodes
            WHERE start_ts >= ? AND start_ts < ? ORDER BY start_ts
            """, [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]) { s in
            DriftEpisode(id: s.int(0), start: Date(timeIntervalSince1970: s.double(1)), end: Date(timeIntervalSince1970: s.double(2)),
                         contextID: s.intOpt(3), clusterID: s.intOpt(4), maxLevel: s.double(5), nudges: Int(s.int(6)),
                         outcome: EpisodeOutcome(rawValue: Int(s.int(7))) ?? .ongoing)
        }
    }

    // MARK: - Learning pipeline

    private static let learningColumns = """
        id, bundle_id, app_name, title, host, url_path, text, total_secs, keys, clicks, scrolls, moves, media_secs, hsin, hcos,
        emb, emb_model, desc, desc_category, desc_topic, desc_emb, cluster_id, cluster_source, cluster_conf, private, last_seen
        """

    private func mapLearning(_ s: SQLStatement) -> LearningContext {
        let secs = s.double(7)
        let hs = s.double(13), hc = s.double(14)
        var meanHour: Double? = nil
        if secs > 0, abs(hs) + abs(hc) > 1e-9 {
            var h = atan2(hs, hc) * 24 / (2 * .pi)
            if h < 0 { h += 24 }
            meanHour = h
        }
        return LearningContext(
            id: s.int(0), bundleID: s.text(1), appName: s.text(2), title: s.text(3), host: s.textOpt(4), urlPath: s.textOpt(5),
            text: s.textOpt(6), totalSeconds: secs,
            behavior: BehaviorStats(seconds: secs, keys: s.double(8), clicks: s.double(9), scrolls: s.double(10),
                                    moves: s.double(11), mediaSeconds: s.double(12)),
            meanHour: meanHour, embedding: s.blob(15)?.floats, embeddingModel: s.textOpt(16), description: s.textOpt(17),
            descriptionCategory: s.textOpt(18), descriptionTopic: s.textOpt(19), descriptionEmbedding: s.blob(20)?.floats,
            clusterID: s.intOpt(21), clusterSource: AssignmentSource(rawValue: Int(s.int(22))) ?? .none,
            clusterConfidence: s.double(23), isPrivate: s.int(24) != 0, lastSeen: Date(timeIntervalSince1970: s.double(25)))
    }

    /// Contexts with at least `minSeconds` of use, heaviest first.
    public func learningContexts(minSeconds: Double, limit: Int) throws -> [LearningContext] {
        try db.query("""
            SELECT \(Self.learningColumns) FROM contexts WHERE total_secs >= ? AND private = 0
            ORDER BY total_secs DESC LIMIT ?
            """, [.double(minSeconds), .int(Int64(limit))], mapLearning)
    }

    public func learningContexts(ids: [ContextID]) throws -> [LearningContext] {
        guard !ids.isEmpty else { return [] }
        // ids are bound as one JSON array (a single cached statement, whatever the list)
        let json = "[" + ids.map(String.init).joined(separator: ",") + "]"
        return try db.query("SELECT \(Self.learningColumns) FROM contexts WHERE id IN (SELECT value FROM json_each(?))",
                            [.text(json)], mapLearning)
    }

    public func contextsNeedingEmbedding(model: String, minSeconds: Double, limit: Int) throws -> [LearningContext] {
        try db.query("""
            SELECT \(Self.learningColumns) FROM contexts
            WHERE total_secs >= ? AND private = 0
              AND (emb IS NULL OR emb_model IS NOT ? OR (text_updated IS NOT NULL AND emb_updated IS NOT NULL AND text_updated > emb_updated + 43200))
            ORDER BY total_secs DESC LIMIT ?
            """, [.double(minSeconds), .text(model), .int(Int64(limit))], mapLearning)
    }

    public func saveEmbedding(id: ContextID, vector: [Float], model: String, now: Date) throws {
        try db.run("UPDATE contexts SET emb = ?, emb_model = ?, emb_updated = ? WHERE id = ?",
                   [.blob(Data(floats: vector)), .text(model), .double(now.timeIntervalSince1970), .int(id)])
    }

    public func contextsNeedingDescription(minSeconds: Double, limit: Int, retryAfter: TimeInterval = 7 * 86400) throws -> [LearningContext] {
        let cutoff = Date().addingTimeInterval(-retryAfter).timeIntervalSince1970
        return try db.query("""
            SELECT \(Self.learningColumns) FROM contexts
            WHERE total_secs >= ? AND private = 0 AND desc IS NULL AND (desc_attempted IS NULL OR desc_attempted < ?)
            ORDER BY total_secs DESC LIMIT ?
            """, [.double(minSeconds), .double(cutoff), .int(Int64(limit))], mapLearning)
    }

    public func saveDescription(id: ContextID, description: String, category: String?, topic: String?, model: String, now: Date) throws {
        try db.run("""
            UPDATE contexts SET desc = ?, desc_category = ?, desc_topic = ?, desc_model = ?, desc_attempted = ?, desc_emb = NULL WHERE id = ?
            """, [.text(description), .opt(category), .opt(topic), .text(model), .double(now.timeIntervalSince1970), .int(id)])
    }

    public func markDescriptionAttempted(id: ContextID, now: Date) throws {
        try db.run("UPDATE contexts SET desc_attempted = ? WHERE id = ?", [.double(now.timeIntervalSince1970), .int(id)])
    }

    public func contextsNeedingDescriptionEmbedding(limit: Int) throws -> [(ContextID, String)] {
        try db.query("SELECT id, desc, desc_category, desc_topic FROM contexts WHERE desc IS NOT NULL AND desc_emb IS NULL LIMIT ?",
                     [.int(Int64(limit))]) { s in
            let parts = [s.text(1), s.textOpt(3), s.textOpt(2)].compactMap { $0 }.filter { !$0.isEmpty }
            return (s.int(0), parts.joined(separator: " — "))
        }
    }

    public func saveDescriptionEmbedding(id: ContextID, vector: [Float]) throws {
        try db.run("UPDATE contexts SET desc_emb = ? WHERE id = ?", [.blob(Data(floats: vector)), .int(id)])
    }

    public func clearDescriptionEmbeddings() throws { try db.run("UPDATE contexts SET desc_emb = NULL") }

    /// Writes activity-type assignments. User assignments are never overwritten by automatic sources.
    public func setAssignments(_ items: [(id: ContextID, cluster: ClusterID?, source: AssignmentSource, confidence: Double)], now: Date) throws {
        try db.transaction {
            for it in items {
                try db.run("""
                    UPDATE contexts SET cluster_id = ?, cluster_source = ?, cluster_conf = ?, cluster_updated = ?
                    WHERE id = ? AND (cluster_source < 4 OR ? = 4)
                    """, [.opt(it.cluster), .int(Int64(it.source.rawValue)), .double(it.confidence),
                          .double(now.timeIntervalSince1970), .int(it.id), .int(Int64(it.source.rawValue))])
            }
        }
    }

    public func assignmentCounts() throws -> [AssignmentSource: Int] {
        var out: [AssignmentSource: Int] = [:]
        for (k, v) in try db.query("SELECT cluster_source, COUNT(*) FROM contexts GROUP BY cluster_source", [], { ($0.int(0), $0.int(1)) }) {
            out[AssignmentSource(rawValue: Int(k)) ?? .none] = Int(v)
        }
        return out
    }

    // MARK: - Clusters

    private func mapCluster(_ s: SQLStatement) -> ActivityCluster {
        func list(_ t: String?) -> [String] {
            guard let t, let d = t.data(using: .utf8), let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
            return a
        }
        return ActivityCluster(id: s.int(0), name: s.textOpt(1), autoName: s.text(2), suggestedName: s.textOpt(3),
                               description: s.textOpt(4), keywords: list(s.textOpt(5)), topApps: list(s.textOpt(6)),
                               color: Int(s.int(7)), userNamed: s.int(8) != 0, archived: s.int(9) != 0,
                               mergedInto: s.intOpt(10), totalSeconds: s.double(11), isNew: s.int(12) != 0)
    }

    private static let clusterColumns = "id, name, auto_name, suggested_name, description, keywords, top_apps, color, user_named, archived, merged_into, total_secs, is_new"

    public func clusters(includeArchived: Bool = false) throws -> [ActivityCluster] {
        try db.query("SELECT \(Self.clusterColumns) FROM clusters \(includeArchived ? "" : "WHERE archived = 0") ORDER BY total_secs DESC",
                     [], mapCluster)
    }

    private static func json(_ a: [String]) -> String {
        (try? String(data: JSONEncoder().encode(a), encoding: .utf8)) ?? "[]"
    }

    /// Cluster ids are never reused (plans and settings refer to them), even across "delete all data".
    private func nextClusterID() throws -> ClusterID {
        let maxID = Int64(try db.scalar("SELECT COALESCE(MAX(id), 0) FROM clusters") ?? 0)
        let high = Int64(try string("clusters.highwater").flatMap { Int64($0) } ?? 0)
        let next = max(maxID, high) + 1
        try setString("clusters.highwater", String(next))
        return next
    }

    public func insertCluster(_ c: ActivityCluster, now: Date) throws -> ClusterID {
        let id = try nextClusterID()
        try db.run("""
            INSERT INTO clusters (id, name, auto_name, suggested_name, description, keywords, top_apps, color, user_named, archived,
              created_at, updated_at, total_secs, is_new) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [.int(id), .opt(c.name), .text(c.autoName), .opt(c.suggestedName), .opt(c.description), .text(Self.json(c.keywords)),
                  .text(Self.json(c.topApps)), .int(Int64(c.color)), .int(c.userNamed ? 1 : 0), .int(c.archived ? 1 : 0),
                  .double(now.timeIntervalSince1970), .double(now.timeIntervalSince1970), .double(c.totalSeconds), .int(c.isNew ? 1 : 0)])
        return id
    }

    /// Records that an archived activity type was replaced by another (so plans referring to it keep working).
    public func setClusterMergedInto(_ id: ClusterID, _ target: ClusterID) throws {
        try db.run("UPDATE clusters SET merged_into = ? WHERE id = ?", [.int(target), .int(id)])
    }

    /// Updates the automatically maintained fields of a cluster (never touches the user's name).
    public func updateClusterMetadata(id: ClusterID, autoName: String, keywords: [String], topApps: [String],
                                      totalSeconds: Double, now: Date) throws {
        try db.run("""
            UPDATE clusters SET auto_name = ?, keywords = ?, top_apps = ?, total_secs = ?, updated_at = ?, archived = 0 WHERE id = ?
            """, [.text(autoName), .text(Self.json(keywords)), .text(Self.json(topApps)), .double(totalSeconds),
                  .double(now.timeIntervalSince1970), .int(id)])
    }

    public func setClusterSuggestion(id: ClusterID, suggestedName: String?, description: String?) throws {
        try db.run("UPDATE clusters SET suggested_name = COALESCE(?, suggested_name), description = COALESCE(?, description) WHERE id = ?",
                   [.opt(suggestedName), .opt(description), .int(id)])
    }

    public func renameCluster(id: ClusterID, name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try db.run("UPDATE clusters SET name = ?, user_named = ?, is_new = 0 WHERE id = ?",
                   [.opt(value), .int(value == nil ? 0 : 1), .int(id)])
    }

    public func setClusterArchived(id: ClusterID, archived: Bool) throws {
        try db.run("UPDATE clusters SET archived = ? WHERE id = ?", [.int(archived ? 1 : 0), .int(id)])
    }

    public func setClusterNew(id: ClusterID, isNew: Bool) throws {
        try db.run("UPDATE clusters SET is_new = ? WHERE id = ?", [.int(isNew ? 1 : 0), .int(id)])
    }

    /// Merges `source` into `target`: all contexts move, the source is archived and remembers where it went.
    public func mergeCluster(_ source: ClusterID, into target: ClusterID) throws {
        try db.transaction {
            try db.run("UPDATE contexts SET cluster_id = ? WHERE cluster_id = ?", [.int(target), .int(source)])
            try db.run("UPDATE segments SET cluster_id = ? WHERE cluster_id = ?", [.int(target), .int(source)])
            try db.run("UPDATE feedback SET cluster_id = ? WHERE cluster_id = ?", [.int(target), .int(source)])
            try db.run("UPDATE clusters SET archived = 1, merged_into = ? WHERE id = ?", [.int(target), .int(source)])
            try db.run("UPDATE clusters SET total_secs = (SELECT COALESCE(SUM(total_secs),0) FROM contexts WHERE cluster_id = ?) WHERE id = ?",
                       [.int(target), .int(target)])
        }
    }

    public func refreshClusterTotals() throws {
        try db.run("UPDATE clusters SET total_secs = (SELECT COALESCE(SUM(total_secs),0) FROM contexts WHERE contexts.cluster_id = clusters.id)")
    }

    /// Top windows of an activity type (for the naming UI).
    public func topContexts(cluster: ClusterID?, limit: Int = 12) throws -> [(title: String, appName: String, host: String?, seconds: Double, id: ContextID)] {
        let sql = cluster == nil
            ? "SELECT title, app_name, host, total_secs, id FROM contexts WHERE cluster_id IS NULL AND private = 0 ORDER BY total_secs DESC LIMIT ?"
            : "SELECT title, app_name, host, total_secs, id FROM contexts WHERE cluster_id = ? AND private = 0 ORDER BY total_secs DESC LIMIT ?"
        let args: [SQLValue] = cluster == nil ? [.int(Int64(limit))] : [.int(cluster!), .int(Int64(limit))]
        return try db.query(sql, args) { ($0.text(0), $0.text(1), $0.textOpt(2), $0.double(3), $0.int(4)) }
    }

    /// The heaviest windows of every activity type (and of the unassigned windows), with what the models saw in them —
    /// the input of `ActivityEvidence`.
    public func evidenceRows(minSeconds: Double, perGroup: Int, excludingBundleIDs: [String] = []) throws -> [EvidenceRow] {
        let excluded = "[" + excludingBundleIDs.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: ",") + "]"
        return try db.query("""
            SELECT id, bundle_id, app_name, title, host, url_path, text, total_secs, keys, clicks, scrolls, moves, media_secs,
                   hsin, hcos, desc, desc_category, desc_topic, cluster_id, cluster_source, cluster_conf, n
            FROM (SELECT id, bundle_id, app_name, title, host, url_path, text, total_secs, keys, clicks, scrolls, moves, media_secs,
                         hsin, hcos, desc, desc_category, desc_topic, cluster_id, cluster_source, cluster_conf,
                         ROW_NUMBER() OVER (PARTITION BY cluster_id ORDER BY total_secs DESC) AS rn,
                         COUNT(*) OVER (PARTITION BY cluster_id) AS n
                  FROM contexts
                  WHERE private = 0 AND total_secs >= ? AND bundle_id NOT IN (SELECT value FROM json_each(?)))
            WHERE rn <= ? ORDER BY total_secs DESC
            """, [.double(minSeconds), .text(excluded), .int(Int64(perGroup))]) { s in
            EvidenceRow(id: s.int(0), bundleID: s.text(1), appName: s.text(2), title: s.text(3), host: s.textOpt(4),
                        urlPath: s.textOpt(5), text: s.textOpt(6),
                        behavior: BehaviorStats(seconds: s.double(7), keys: s.double(8), clicks: s.double(9), scrolls: s.double(10),
                                                moves: s.double(11), mediaSeconds: s.double(12)),
                        hourSin: s.double(13), hourCos: s.double(14), activity: s.textOpt(15), category: s.textOpt(16),
                        topic: s.textOpt(17), clusterID: s.intOpt(18),
                        assignment: AssignmentSource(rawValue: Int(s.int(19))) ?? .none, confidence: s.double(20),
                        groupWindows: Int(s.int(21)))
        }
    }

    // MARK: - Feedback

    public func addFeedback(contextID: ContextID, clusterID: ClusterID?, kind: FeedbackKind, now: Date = Date()) throws {
        try db.run("INSERT INTO feedback (ts, context_id, cluster_id, kind) VALUES (?,?,?,?)",
                   [.double(now.timeIntervalSince1970), .int(contextID), .opt(clusterID), .int(Int64(kind.rawValue))])
    }

    public func allowedContexts(since: Date) throws -> Set<ContextID> {
        Set(try db.query("SELECT context_id FROM feedback WHERE kind = 1 AND ts >= ?", [.double(since.timeIntervalSince1970)]) { $0.int(0) })
    }

    public func feedbackCount() throws -> Int { Int(try db.scalar("SELECT COUNT(*) FROM feedback") ?? 0) }

    // MARK: - Plans

    public func plan(day: String) throws -> DayPlan? {
        guard let json = try db.query("SELECT json FROM plans WHERE day = ?", [.text(day)], { $0.text(0) }).first,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DayPlan.self, from: data)
    }

    public func savePlan(_ plan: DayPlan) throws {
        let json = String(data: try JSONEncoder().encode(plan), encoding: .utf8) ?? "{}"
        try db.run("INSERT OR REPLACE INTO plans (day, json) VALUES (?, ?)", [.text(plan.day), .text(json)])
    }

    public func latestPlan(before day: String) throws -> DayPlan? {
        guard let json = try db.query("SELECT json FROM plans WHERE day < ? ORDER BY day DESC LIMIT 1", [.text(day)], { $0.text(0) }).first,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DayPlan.self, from: data)
    }

    // MARK: - Key/value

    public func data(_ key: String) throws -> Data? {
        try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]) { $0.blob(0) }.first ?? nil
    }

    public func setData(_ key: String, _ value: Data?) throws {
        if let value {
            try db.run("INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", [.text(key), .blob(value)])
        } else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
        }
    }

    public func string(_ key: String) throws -> String? { try data(key).flatMap { String(data: $0, encoding: .utf8) } }
    public func setString(_ key: String, _ value: String?) throws { try setData(key, value?.data(using: .utf8)) }
    public func codable<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let d = try? data(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    public func setCodable<T: Encodable>(_ key: String, _ value: T) throws { try setData(key, try JSONEncoder().encode(value)) }

    // MARK: - Counters & housekeeping

    public struct Counts: Equatable {
        public var contexts = 0, embedded = 0, described = 0, assigned = 0, segments = 0
        public var trackedSeconds: Double = 0
    }

    public func counts(model: String?) throws -> Counts {
        var c = Counts()
        c.contexts = Int(try db.scalar("SELECT COUNT(*) FROM contexts") ?? 0)
        c.embedded = Int(try db.scalar("SELECT COUNT(*) FROM contexts WHERE emb IS NOT NULL AND emb_model IS ?", [.opt(model)]) ?? 0)
        c.described = Int(try db.scalar("SELECT COUNT(*) FROM contexts WHERE desc IS NOT NULL") ?? 0)
        c.assigned = Int(try db.scalar("SELECT COUNT(*) FROM contexts WHERE cluster_id IS NOT NULL") ?? 0)
        c.segments = Int(try db.scalar("SELECT COUNT(*) FROM segments") ?? 0)
        c.trackedSeconds = try db.scalar("SELECT COALESCE(SUM(active_secs),0) FROM segments") ?? 0
        return c
    }

    /// Privacy retention: forget raw window text after N days (embeddings and abstract descriptions remain).
    public func purgeText(olderThan date: Date) throws {
        try db.run("UPDATE contexts SET text = NULL WHERE text_updated IS NOT NULL AND text_updated < ?", [.double(date.timeIntervalSince1970)])
    }

    public func purgeSegments(olderThan date: Date) throws {
        try db.run("DELETE FROM segments WHERE end_ts < ?", [.double(date.timeIntervalSince1970)])
        try db.run("DELETE FROM episodes WHERE end_ts < ?", [.double(date.timeIntervalSince1970)])
    }

    public func deleteAllData() throws {
        let maxID = Int64(try db.scalar("SELECT COALESCE(MAX(id), 0) FROM clusters") ?? 0)
        let high = max(maxID, Int64(try string("clusters.highwater").flatMap { Int64($0) } ?? 0))
        try db.script("DELETE FROM segments; DELETE FROM episodes; DELETE FROM feedback; DELETE FROM contexts; DELETE FROM clusters; DELETE FROM plans; DELETE FROM kv;")
        try setString("clusters.highwater", String(high)) // ids stay unique forever
        try db.script("VACUUM;")
    }
}
