import Foundation

/// SentencePiece "precompiled charsmap" normaliser (XLM-R uses Google's `nmt_nfkc` rules: NFKC plus
/// whitespace/control-character clean-up).
///
/// Blob layout (`precompiled_charsmap`, base64 in tokenizer.json):
///   `u32 LE trie byte size` · darts-clone double-array trie (u32 units) · NUL-separated replacements.
/// Trie keys are UTF-8 byte strings; a leaf's value is the offset of the replacement string.
///
/// `normalize` is a faithful port of HuggingFace `tokenizers`' `Precompiled` normaliser (crate
/// `spm_precompiled`), which differs slightly from SentencePiece's own longest-match scan:
/// the text is walked by *extended grapheme cluster*; a cluster shorter than 6 UTF-8 bytes is first
/// looked up as a whole (taking the *shortest* trie prefix match, as the Rust code does); otherwise,
/// or when that fails, each Unicode scalar of the cluster is looked up on its own.
struct PrecompiledCharsMap {
    private let units: [UInt32]
    private let replacements: [UInt8]

    init(blob: [UInt8]) throws {
        guard blob.count >= 4 else { throw EncoderError.badConfig("precompiled_charsmap too short") }
        let trieBytes = Int(UInt32(blob[0]) | UInt32(blob[1]) << 8 | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
        guard trieBytes % 4 == 0, 4 + trieBytes <= blob.count, trieBytes >= 4 else {
            throw EncoderError.badConfig("precompiled_charsmap has an invalid trie size")
        }
        var units = [UInt32](repeating: 0, count: trieBytes / 4)
        for i in 0..<units.count {
            let o = 4 + 4 * i
            units[i] = UInt32(blob[o]) | UInt32(blob[o + 1]) << 8 | UInt32(blob[o + 2]) << 16 | UInt32(blob[o + 3]) << 24
        }
        self.units = units
        self.replacements = Array(blob[(4 + trieBytes)...])
    }

    init(base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw EncoderError.badConfig("precompiled_charsmap is not valid base64")
        }
        try self.init(blob: [UInt8](data))
    }

    /// darts-clone `commonPrefixSearch`, returning only the first (= shortest) match, exactly like
    /// `spm_precompiled::Precompiled::transform`. Returns the replacement's byte range.
    @inline(__always)
    private func firstMatch(_ key: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        units.withUnsafeBufferPointer { a -> Range<Int>? in
            let n = a.count
            var pos = 0
            var unit = a[0]
            pos ^= Self.offset(unit)
            for c in key {
                if c == 0 { return nil }
                pos ^= Int(c)
                guard pos < n else { return nil }
                unit = a[pos]
                if unit & 0x8000_00FF != UInt32(c) { return nil }   // label mismatch (leaf units carry the MSB)
                pos ^= Self.offset(unit)
                guard pos < n else { return nil }
                if (unit >> 8) & 1 == 1 {                              // has_leaf
                    let start = Int(a[pos] & 0x7FFF_FFFF)
                    guard start <= replacements.count else { return nil }
                    var end = start
                    while end < replacements.count && replacements[end] != 0 { end += 1 }
                    return start..<end
                }
            }
            return nil
        }
    }

    @inline(__always)
    private static func offset(_ unit: UInt32) -> Int {
        Int((unit >> 10) << ((unit & (1 << 9)) >> 6))
    }

    func normalize(_ text: String) -> String {
        if text.isEmpty { return text }
        let src = Array(text.utf8)
        // Walk a native UTF-8 copy so the per-Character byte counts provably line up with `src`
        // (bridged NSStrings are transcoded on the fly).
        let native = String(decoding: src, as: UTF8.self)
        var out = [UInt8]()
        out.reserveCapacity(src.count + 8)
        var changed = false
        src.withUnsafeBufferPointer { bytes in
            var pos = 0
            for character in native {
                let len = min(character.utf8.count, bytes.count - pos)
                let cluster = UnsafeBufferPointer(rebasing: bytes[pos ..< pos + len])
                pos += len
                if len < 6, let r = firstMatch(cluster) {
                    out.append(contentsOf: replacements[r])
                    changed = true
                    continue
                }
                var p = 0
                while p < len {
                    let scalarLen = min(utf8SequenceLength(cluster[p]), len - p)
                    let scalar = UnsafeBufferPointer(rebasing: cluster[p ..< p + scalarLen])
                    if let r = firstMatch(scalar) {
                        out.append(contentsOf: replacements[r])
                        changed = true
                    } else {
                        out.append(contentsOf: scalar)
                    }
                    p += scalarLen
                }
            }
        }
        return changed ? String(decoding: out, as: UTF8.self) : text
    }
}

/// Byte length of the UTF-8 sequence introduced by `lead`.
@inline(__always)
func utf8SequenceLength(_ lead: UInt8) -> Int {
    if lead < 0x80 { return 1 }
    if lead < 0xE0 { return 2 }
    if lead < 0xF0 { return 3 }
    return 4
}

/// The normaliser pipeline declared in tokenizer.json (`normalizer` field).
struct TextNormalizer {
    enum Step {
        case precompiled(PrecompiledCharsMap)
        case replaceRegex(NSRegularExpression, template: String)
        case replaceLiteral(String, String)
        case strip(left: Bool, right: Bool)
        case nfc, nfd, nfkc, nfkd
        case lowercase
        case prepend(String)
    }

    let steps: [Step]

    init(json: Any?) throws {
        var steps: [Step] = []
        try TextNormalizer.collect(json, into: &steps)
        self.steps = steps
    }

    private static func collect(_ json: Any?, into steps: inout [Step]) throws {
        guard let spec = json as? [String: Any] else { return }   // null → identity
        let type = spec["type"] as? String ?? ""
        switch type {
        case "Sequence":
            for n in spec["normalizers"] as? [Any] ?? [] { try collect(n, into: &steps) }
        case "Precompiled":
            if let b64 = spec["precompiled_charsmap"] as? String, !b64.isEmpty {
                steps.append(.precompiled(try PrecompiledCharsMap(base64: b64)))
            }
        case "Replace":
            let content = spec["content"] as? String ?? ""
            let pattern = spec["pattern"] as? [String: Any] ?? [:]
            if let regex = pattern["Regex"] as? String {
                do {
                    let re = try NSRegularExpression(pattern: regex)
                    steps.append(.replaceRegex(re, template: NSRegularExpression.escapedTemplate(for: content)))
                } catch {
                    throw EncoderError.unsupported("normalizer regex '\(regex)'")
                }
            } else if let literal = pattern["String"] as? String {
                if !literal.isEmpty { steps.append(.replaceLiteral(literal, content)) }
            } else {
                throw EncoderError.badConfig("Replace normalizer without pattern")
            }
        case "Strip":
            steps.append(.strip(left: spec["strip_left"] as? Bool ?? true, right: spec["strip_right"] as? Bool ?? true))
        case "NFC": steps.append(.nfc)
        case "NFD": steps.append(.nfd)
        case "NFKC": steps.append(.nfkc)
        case "NFKD": steps.append(.nfkd)
        case "Lowercase": steps.append(.lowercase)
        case "Prepend": steps.append(.prepend(spec["prepend"] as? String ?? ""))
        default:
            throw EncoderError.unsupported("normalizer '\(type)'")
        }
    }

    func apply(_ input: String) -> String {
        var s = input
        for step in steps {
            if s.isEmpty { break }
            switch step {
            case .precompiled(let map):
                s = map.normalize(s)
            case .replaceRegex(let re, let template):
                let ns = s as NSString
                s = re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length),
                                                withTemplate: template)
            case .replaceLiteral(let pattern, let content):
                s = s.replacingOccurrences(of: pattern, with: content, options: .literal)
            case .strip(let left, let right):
                s = stripWhitespace(s, left: left, right: right)
            case .nfc: s = s.precomposedStringWithCanonicalMapping
            case .nfd: s = s.decomposedStringWithCanonicalMapping
            case .nfkc: s = s.precomposedStringWithCompatibilityMapping
            case .nfkd: s = s.decomposedStringWithCompatibilityMapping
            case .lowercase: s = s.lowercased()
            case .prepend(let p): s = p + s
            }
        }
        return s
    }
}

/// Trims Unicode `White_Space` scalars (Rust `char::is_whitespace`) from either end.
func stripWhitespace(_ s: String, left: Bool, right: Bool) -> String {
    var scalars = Substring(s).unicodeScalars
    if left { while let f = scalars.first, f.properties.isWhitespace { scalars.removeFirst() } }
    if right { while let l = scalars.last, l.properties.isWhitespace { scalars.removeLast() } }
    return String(Substring(scalars))
}
