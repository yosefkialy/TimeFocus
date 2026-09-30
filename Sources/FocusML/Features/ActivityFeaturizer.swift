import Foundation

/// Behavioural statistics of an activity context (aggregated over the time it was on screen).
public struct BehaviorStats: Codable, Equatable {
    public var seconds: Double
    public var keys: Double
    public var clicks: Double
    public var scrolls: Double
    public var moves: Double
    public var mediaSeconds: Double

    public init(seconds: Double = 0, keys: Double = 0, clicks: Double = 0, scrolls: Double = 0, moves: Double = 0, mediaSeconds: Double = 0) {
        self.seconds = seconds; self.keys = keys; self.clicks = clicks; self.scrolls = scrolls; self.moves = moves; self.mediaSeconds = mediaSeconds
    }

    public var minutes: Double { max(seconds / 60, 1.0 / 60) }
    public var keysPerMin: Double { keys / minutes }
    public var clicksPerMin: Double { clicks / minutes }
    public var scrollsPerMin: Double { scrolls / minutes }
    public var movesPerMin: Double { moves / minutes }
    public var mediaFraction: Double { seconds > 0 ? min(1, mediaSeconds / seconds) : 0 }

    /// Compact behaviour signature used by clustering (roughly standardised, ~unit scale).
    public var signature: [Float] {
        [Float(log1p(keysPerMin) / 3), Float(log1p(clicksPerMin) / 2.5), Float(log1p(scrollsPerMin) / 3),
         Float(log1p(movesPerMin) / 5), Float(mediaFraction)]
    }
}

/// Everything the real-time student network may look at for one activity context.
public struct ActivityDescriptor {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var host: String?
    public var urlPath: String?
    public var text: String?
    public var behavior: BehaviorStats
    public var hourOfDay: Double?

    public init(bundleID: String, appName: String, title: String, host: String? = nil, urlPath: String? = nil,
                text: String? = nil, behavior: BehaviorStats = BehaviorStats(), hourOfDay: Double? = nil) {
        self.bundleID = bundleID; self.appName = appName; self.title = title; self.host = host
        self.urlPath = urlPath; self.text = text; self.behavior = behavior; self.hourOfDay = hourOfDay
    }
}

/// Feature groups; used for weight budgets and for field-dropout augmentation during training.
public enum FeatureField: UInt8, CaseIterable {
    case app = 0, host = 1, path = 2, title = 3, titleGrams = 4, text = 5
}

/// Output of the featurizer: a sparse hashed bag (with field ids) plus dense behaviour features.
public struct FeaturizedActivity {
    public var sparse: SparseVector
    public var fields: [UInt8]
    public var dense: [Float]
    public init(sparse: SparseVector, fields: [UInt8], dense: [Float]) { self.sparse = sparse; self.fields = fields; self.dense = dense }
}

/// Turns an `ActivityDescriptor` into hashed sparse features. Each field gets a fixed weight budget so that a long
/// page of text cannot drown out the app / site identity, and so the network learns from all views of the activity.
public struct ActivityFeaturizer {
    public static let denseDim = 9
    public let hasher: FeatureHasher

    public static let budgets: [FeatureField: Float] = [
        .app: 3.0, .host: 3.0, .path: 1.2, .title: 3.0, .titleGrams: 1.5, .text: 2.5,
    ]

    public init(buckets: Int = 1 << 16) { hasher = FeatureHasher(buckets: buckets) }

    private static let salts: [FeatureField: UInt64] = [
        .app: 0x1111, .host: 0x2222, .path: 0x3333, .title: 0x4444, .titleGrams: 0x5555, .text: 0x6666,
    ]

    public func featurize(_ d: ActivityDescriptor) -> FeaturizedActivity {
        var groups: [FeatureField: [String]] = [:]
        groups[.app] = [d.bundleID.lowercased(), "name:" + d.appName.lowercased()]

        if let host = d.host, !host.isEmpty {
            var hostTokens = [host]
            let parts = host.split(separator: ".")
            if parts.count >= 2 { hostTokens.append(parts.suffix(2).joined(separator: ".")) }
            if parts.count >= 3 { hostTokens.append("sub:" + parts[0]) }
            groups[.host] = hostTokens
        }
        if let path = d.urlPath, !path.isEmpty {
            groups[.path] = TextTokenizer.pathTokens(path)
        }

        let titleWords = TextTokenizer.words(d.title, maxTokens: 40)
        var titleTokens = titleWords.filter { !TextTokenizer.isStopword($0) }
        for w in titleWords { titleTokens.append(contentsOf: TextTokenizer.hebrewVariants(w)) }
        if titleWords.count >= 2 {
            for i in 0..<(titleWords.count - 1) { titleTokens.append(titleWords[i] + "_" + titleWords[i + 1]) }
        }
        groups[.title] = titleTokens
        groups[.titleGrams] = titleWords.prefix(20).flatMap { TextTokenizer.charNGrams($0, sizes: [3]) }

        if let text = d.text, !text.isEmpty {
            var textTokens = TextTokenizer.contentWords(text, maxTokens: 600)
            textTokens.append(contentsOf: textTokens.prefix(200).flatMap { TextTokenizer.hebrewVariants($0) })
            groups[.text] = textTokens
        }

        var sparse = SparseVector()
        var fields: [UInt8] = []
        for field in FeatureField.allCases {
            guard let tokens = groups[field], !tokens.isEmpty else { continue }
            // aggregate duplicates, then spread the field budget over distinct tokens (sub-linear in term frequency)
            var counts: [String: Int] = [:]
            for t in tokens { counts[t, default: 0] += 1 }
            let raw = counts.mapValues { Float(1 + log(Double($0))) }
            let total = raw.values.reduce(0, +)
            let budget = Self.budgets[field] ?? 1
            let salt = Self.salts[field] ?? 0
            for (tok, r) in raw.sorted(by: { $0.key < $1.key }) {
                sparse.append(hasher.index(tok, field: salt), budget * r / total)
                fields.append(field.rawValue)
            }
        }
        return FeaturizedActivity(sparse: sparse, fields: fields, dense: denseFeatures(d))
    }

    public func denseFeatures(_ d: ActivityDescriptor) -> [Float] {
        let b = d.behavior
        var f = [Float](repeating: 0, count: Self.denseDim)
        f[0] = Float(log1p(b.keysPerMin) / 3)
        f[1] = Float(log1p(b.clicksPerMin) / 2.5)
        f[2] = Float(log1p(b.scrollsPerMin) / 3)
        f[3] = Float(log1p(b.movesPerMin) / 5)
        f[4] = Float(b.mediaFraction)
        if let h = d.hourOfDay {
            f[5] = Float(sin(2 * .pi * h / 24))
            f[6] = Float(cos(2 * .pi * h / 24))
        }
        f[7] = (d.host?.isEmpty == false) ? 1 : 0
        f[8] = Float(log1p(Double(d.title.count)) / 4)
        return f
    }
}
