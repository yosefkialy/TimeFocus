import Foundation

/// Model-free fallback "teacher": signed feature hashing of words + character n-grams into a dense vector.
/// Used only when no neural sentence encoder is installed, so the pipeline always works end-to-end.
public struct HashingEmbedder {
    public let dimension: Int
    public static let modelID = "hashing-v1"
    private let hasher: FeatureHasher

    public init(dimension: Int = 384) {
        self.dimension = dimension
        hasher = FeatureHasher(buckets: dimension)
    }

    public func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        let words = TextTokenizer.contentWords(text, maxTokens: 400)
        var counts: [String: Float] = [:]
        for w in words {
            counts["w:" + w, default: 0] += 1
            for variant in TextTokenizer.hebrewVariants(w) { counts["w:" + variant, default: 0] += 0.6 }
            for g in TextTokenizer.charNGrams(w, sizes: [3]) { counts["g:" + g, default: 0] += 0.25 }
        }
        for (tok, c) in counts {
            let (i, sign) = hasher.signedIndex(tok, field: 0xABCD)
            v[Int(i)] += sign * (1 + log(c))
        }
        return LA.normalized(v)
    }
}

/// Input for the combined activity representation used by clustering and prototype matching.
public struct RepresentationInput {
    public var textEmbedding: [Float]
    public var descriptionEmbedding: [Float]?
    public var bundleID: String
    public var host: String?
    public var behavior: BehaviorStats
    /// Soft profile over generic activity kinds (zero-shot semantic anchors), if available.
    public var categoryProfile: [Float]?
    /// 0…1: how much the behaviour statistics can be trusted (brief observation → treated as average).
    public var behaviorConfidence: Float
    public init(textEmbedding: [Float], descriptionEmbedding: [Float]?, bundleID: String, host: String?, behavior: BehaviorStats,
                categoryProfile: [Float]? = nil, behaviorConfidence: Float = 1) {
        self.textEmbedding = textEmbedding; self.descriptionEmbedding = descriptionEmbedding
        self.bundleID = bundleID; self.host = host; self.behavior = behavior; self.categoryProfile = categoryProfile
        self.behaviorConfidence = behaviorConfidence
    }
}

/// Builds one L2-normalised vector per activity that fuses several views:
///   • semantic embedding of the raw window text (teacher encoder, or the student's distilled estimate in real time)
///   • semantic embedding of the LLM's abstract activity description ("studying linear algebra", "watching comedy")
///     — this is what keeps "the same kind of activity" together when the raw text changes completely
///   • app / site identity
///   • behaviour (typing, scrolling, clicking, media playback)
/// Embeddings are mean-centred on the user's own corpus, which removes the shared "anisotropy" direction of
/// transformer embeddings and makes cosine distances far more discriminative.
public struct RepresentationBuilder: Codable {
    public var textWeight: Float = 1.0
    public var descriptionWeight: Float = 0.8
    public var appWeight: Float = 0.35
    public var behaviorWeight: Float = 0.3
    public var categoryWeight: Float = 0.9
    public var appDim = 32
    public var categoryDim = 0
    public var textMean: [Float] = []
    public var descriptionMean: [Float] = []
    public var behaviorMean: [Float] = []
    public var behaviorStd: [Float] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case textWeight, descriptionWeight, appWeight, behaviorWeight, categoryWeight, appDim, categoryDim
        case textMean, descriptionMean, behaviorMean, behaviorStd
    }

    /// Tolerant decoding: fields added in later versions fall back to their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textWeight = try c.decodeIfPresent(Float.self, forKey: .textWeight) ?? textWeight
        descriptionWeight = try c.decodeIfPresent(Float.self, forKey: .descriptionWeight) ?? descriptionWeight
        appWeight = try c.decodeIfPresent(Float.self, forKey: .appWeight) ?? appWeight
        behaviorWeight = try c.decodeIfPresent(Float.self, forKey: .behaviorWeight) ?? behaviorWeight
        categoryWeight = try c.decodeIfPresent(Float.self, forKey: .categoryWeight) ?? categoryWeight
        appDim = try c.decodeIfPresent(Int.self, forKey: .appDim) ?? appDim
        categoryDim = try c.decodeIfPresent(Int.self, forKey: .categoryDim) ?? 0
        textMean = try c.decodeIfPresent([Float].self, forKey: .textMean) ?? []
        descriptionMean = try c.decodeIfPresent([Float].self, forKey: .descriptionMean) ?? []
        behaviorMean = try c.decodeIfPresent([Float].self, forKey: .behaviorMean) ?? []
        behaviorStd = try c.decodeIfPresent([Float].self, forKey: .behaviorStd) ?? []
    }

    public var isFitted: Bool { !textMean.isEmpty }

    public mutating func fit(_ inputs: [RepresentationInput], weights: [Float]) {
        guard !inputs.isEmpty else { return }
        categoryDim = inputs.first { $0.categoryProfile != nil }?.categoryProfile?.count ?? 0
        textMean = LA.mean(inputs.map(\.textEmbedding), weights: weights)
        let withDesc = inputs.indices.filter { inputs[$0].descriptionEmbedding != nil }
        descriptionMean = withDesc.isEmpty ? textMean
            : LA.mean(withDesc.map { inputs[$0].descriptionEmbedding! }, weights: withDesc.map { weights[$0] })
        let sigs = inputs.map(\.behavior.signature)
        let d = sigs[0].count
        behaviorMean = LA.mean(sigs, weights: weights)
        behaviorStd = (0..<d).map { k in
            let wsum = weights.reduce(0, +)
            let v = zip(sigs, weights).reduce(Float(0)) { $0 + $1.1 * pow($1.0[k] - behaviorMean[k], 2) } / max(wsum, 1e-6)
            return max(v.squareRoot(), 0.05)
        }
    }

    public func appVector(bundleID: String, host: String?) -> [Float] {
        let hasher = FeatureHasher(buckets: appDim)
        var v = [Float](repeating: 0, count: appDim)
        for (tok, w) in [("app:" + bundleID.lowercased(), Float(1.0))] + (host.map { [("host:" + $0, Float(1.0))] } ?? []) {
            // 3 hashes per token → smoother similarity structure
            for salt in UInt64(1)...3 {
                let (i, s) = hasher.signedIndex(tok, field: salt)
                v[Int(i)] += s * w
            }
        }
        return LA.normalized(v)
    }

    public func represent(_ x: RepresentationInput) -> [Float] {
        var t = x.textEmbedding
        if t.count == textMean.count { LA.axpy(&t, textMean, -1) }
        t = LA.normalized(t)
        var d: [Float]
        if let de = x.descriptionEmbedding {
            d = de
            if d.count == descriptionMean.count { LA.axpy(&d, descriptionMean, -1) }
            d = LA.normalized(d)
        } else {
            d = t
        }
        let a = appVector(bundleID: x.bundleID, host: x.host)
        var b = x.behavior.signature
        if behaviorMean.count == b.count {
            for k in 0..<b.count { b[k] = max(-2, min(2, (b[k] - behaviorMean[k]) / behaviorStd[k])) * x.behaviorConfidence }
        }
        let bScale = behaviorWeight / (2 * Float(b.count).squareRoot())
        var out: [Float] = []
        out.reserveCapacity(t.count + d.count + a.count + b.count + categoryDim)
        out.append(contentsOf: t.map { $0 * textWeight })
        out.append(contentsOf: d.map { $0 * descriptionWeight })
        out.append(contentsOf: a.map { $0 * appWeight })
        out.append(contentsOf: b.map { $0 * bScale })
        if categoryDim > 0 {
            if let p = x.categoryProfile, p.count == categoryDim {
                out.append(contentsOf: LA.normalized(p).map { $0 * categoryWeight })
            } else {
                out.append(contentsOf: [Float](repeating: 0, count: categoryDim))
            }
        }
        return LA.normalized(out)
    }
}
