import Foundation

/// 64-bit FNV-1a hash of a string's UTF-8 bytes, optionally salted with a field name.
@inline(__always)
public func fnv1a64(_ s: String, salt: UInt64 = 0) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01B3
    }
    // final avalanche (murmur3 fmix64) so low bits are well mixed for modulo bucketing
    h ^= h >> 33; h = h &* 0xff51_afd7_ed55_8ccd
    h ^= h >> 33; h = h &* 0xc4ce_b9fe_1a85_ec53
    h ^= h >> 33
    return h
}

/// Sparse feature vector (bucket index → value).
public struct SparseVector: Codable, Equatable {
    public var indices: [Int32]
    public var values: [Float]
    public init(indices: [Int32] = [], values: [Float] = []) { self.indices = indices; self.values = values }
    public var isEmpty: Bool { indices.isEmpty }
    public mutating func append(_ index: Int32, _ value: Float) { indices.append(index); values.append(value) }
}

/// Language-agnostic tokenisation shared by the student network, the hashing embedder and keyword extraction.
/// Handles Hebrew (strips common one-letter prefixes as extra variants) and Latin scripts; never needs a model.
public enum TextTokenizer {
    public static let englishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "from", "is", "are", "was",
        "be", "this", "that", "it", "as", "you", "your", "we", "our", "i", "my", "me", "not", "no", "yes", "but", "if",
        "then", "so", "do", "does", "can", "will", "all", "any", "more", "new", "how", "what", "when", "who", "why",
        "which", "about", "into", "out", "up", "down", "over", "use", "using", "via", "per", "vs", "etc", "com", "www",
        "http", "https", "html", "htm", "php", "index", "page", "untitled", "home", "de", "la", "le", "et", "el",
    ]
    public static let hebrewStopwords: Set<String> = [
        "של", "את", "על", "עם", "זה", "זו", "זאת", "אני", "אתה", "את", "הוא", "היא", "אנחנו", "הם", "הן", "לא", "כן",
        "גם", "או", "אם", "כי", "מה", "מי", "איך", "למה", "כל", "יש", "אין", "היה", "היו", "להיות", "אל", "עד", "בין",
        "אבל", "רק", "עוד", "כך", "כמו", "לכל", "שלי", "שלך", "שלו", "שלה", "אותו", "אותה", "הזה", "הזאת", "אחד", "אחת",
        "ה", "ו", "ב", "ל", "מ", "ש", "כ",
    ]

    public static func isStopword(_ w: String) -> Bool { englishStopwords.contains(w) || hebrewStopwords.contains(w) }

    @inline(__always)
    static func isHebrewLetter(_ u: Unicode.Scalar) -> Bool { (0x05D0...0x05EA).contains(u.value) }

    /// Lower-cased word tokens. Numbers are kept only if short (years, versions); long digit runs become "#num".
    public static func words(_ text: String, maxTokens: Int = 4000) -> [String] {
        var out: [String] = []
        out.reserveCapacity(min(maxTokens, text.count / 4 + 1))
        var current = String.UnicodeScalarView()
        func flush() {
            guard !current.isEmpty else { return }
            let w = String(current).lowercased()
            current.removeAll(keepingCapacity: true)
            if w.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                out.append(w.count <= 4 ? w : "#num")
            } else {
                out.append(w)
            }
        }
        for u in text.unicodeScalars {
            if out.count >= maxTokens { break }
            // Hebrew niqqud / cantillation marks are dropped; letters, digits and joiners are kept.
            if (0x0591...0x05C7).contains(u.value) { continue }
            if CharacterSet.alphanumerics.contains(u) || u == "_" {
                current.append(u)
            } else if (u == "'" || u == "\"" || u == "״" || u == "׳"), !current.isEmpty,
                      let last = current.last, isHebrewLetter(last) {
                continue // Hebrew acronyms/geresh: צה"ל → צהל
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// Hebrew words often carry one-letter proclitics (ו/ה/ב/ל/מ/ש/כ). Emit stripped variants to improve matching.
    public static func hebrewVariants(_ w: String) -> [String] {
        let scalars = Array(w.unicodeScalars)
        guard scalars.count >= 4, isHebrewLetter(scalars[0]) else { return [] }
        let prefixes: Set<Unicode.Scalar> = ["ו", "ה", "ב", "ל", "מ", "ש", "כ"]
        var variants: [String] = []
        var i = 0
        while i < 2, scalars.count - i >= 4, prefixes.contains(scalars[i]) {
            i += 1
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[i...])
            variants.append(String(v))
        }
        return variants
    }

    /// Character n-grams with boundary markers ("<wor", "ord>" …) — robust to morphology, typos and new words.
    public static func charNGrams(_ w: String, sizes: [Int] = [3, 4]) -> [String] {
        let chars = Array("<" + w + ">")
        var grams: [String] = []
        for n in sizes where chars.count >= n {
            for i in 0...(chars.count - n) { grams.append(String(chars[i..<(i + n)])) }
        }
        return grams
    }

    /// Words suitable for keyword display (no stopwords, no numbers, length ≥ 2).
    public static func contentWords(_ text: String, maxTokens: Int = 4000) -> [String] {
        words(text, maxTokens: maxTokens).filter { w in
            w.count >= 2 && w != "#num" && !isStopword(w) && !w.allSatisfy({ $0.isNumber })
        }
    }

    /// Splits a URL path into readable tokens ("/docs/linear-algebra/unit5" → ["docs", "linear", "algebra", "unit5"]).
    public static func pathTokens(_ path: String, maxSegments: Int = 4) -> [String] {
        let segments = path.split(separator: "/").prefix(maxSegments)
        return segments.flatMap { seg -> [String] in
            let decoded = String(seg).removingPercentEncoding ?? String(seg)
            return words(decoded.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
                .filter { $0.count <= 30 }
        }
    }
}

/// Maps salted string features into a fixed number of hash buckets.
public struct FeatureHasher: Codable, Equatable {
    public let buckets: Int
    public init(buckets: Int) { self.buckets = buckets }

    @inline(__always)
    public func index(_ token: String, field: UInt64) -> Int32 {
        Int32(truncatingIfNeeded: fnv1a64(token, salt: field) % UInt64(buckets))
    }

    @inline(__always)
    public func signedIndex(_ token: String, field: UInt64) -> (Int32, Float) {
        let h = fnv1a64(token, salt: field)
        return (Int32(truncatingIfNeeded: (h >> 1) % UInt64(buckets)), (h & 1) == 0 ? 1 : -1)
    }
}
