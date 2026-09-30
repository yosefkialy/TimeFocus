import Foundation

/// SentencePiece-**Unigram** tokenizer driven by a HuggingFace `tokenizer.json`, reproducing the
/// Rust `tokenizers` pipeline step by step:
///
///  1. added/special tokens (`<s>`, `</s>`, `<unk>`, `<pad>`, `<mask>` …) are cut out of the raw text
///     (leftmost-longest match, honouring `single_word` / `lstrip` / `rstrip`);
///  2. every remaining segment is normalised on its own (XLM-R: Precompiled `nmt_nfkc` charsmap, then
///     `Replace(" {2,}" → " ")`); added tokens flagged `normalized` are then cut from the result;
///  3. pre-tokenizer: Metaspace (`" "` → `"▁"`, prepend `"▁"`, split in front of every `"▁"`);
///  4. Unigram model: Viterbi best segmentation of each piece over the vocabulary log-probabilities,
///     unknown characters scored `min_score − 10` and consecutive unknowns fused into one `<unk>`;
///  5. post-processor template (`<s> $A </s>`) with right-side truncation.
///
/// Instances are immutable after `init`, so concurrent use is safe.
final class UnigramTokenizer {
    struct AddedToken {
        let id: Int32
        let content: [UInt8]
        let singleWord: Bool
        let lstrip: Bool
        let rstrip: Bool
    }

    private let rawAddedTokens: [AddedToken]
    private let normalizedAddedTokens: [AddedToken]
    private let normalizer: TextNormalizer
    private let preTokenizer: PreTokenizer
    private let model: UnigramModel
    /// Special ids the post-processor puts before / after the sequence (`[<s>]`, `[</s>]`).
    let prefixIds: [Int32]
    let suffixIds: [Int32]
    /// One past the largest token id this tokenizer can emit.
    let vocabularySize: Int

    var specialTokenCount: Int { prefixIds.count + suffixIds.count }
    var approximateMemoryBytes: Int { model.approximateMemoryBytes }

    convenience init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw EncoderError.missingFile(url.lastPathComponent)
        }
        let root: [String: Any]? = try autoreleasepool {
            do { return try JSONSerialization.jsonObject(with: data) as? [String: Any] } catch {
                throw EncoderError.badConfig("tokenizer.json is not valid JSON")
            }
        }
        guard let root else { throw EncoderError.badConfig("tokenizer.json is not a JSON object") }
        try self.init(json: root)
    }

    init(json: [String: Any]) throws {
        guard let modelSpec = json["model"] as? [String: Any] else {
            throw EncoderError.badConfig("tokenizer.json has no model")
        }
        let modelType = modelSpec["type"] as? String ?? ""
        guard modelType == "Unigram" else {
            throw EncoderError.unsupported("tokenizer model '\(modelType)' (only SentencePiece Unigram is implemented)")
        }
        model = try UnigramModel(json: modelSpec)
        normalizer = try TextNormalizer(json: json["normalizer"])
        preTokenizer = try PreTokenizer(json: json["pre_tokenizer"])
        (prefixIds, suffixIds) = try UnigramTokenizer.parsePostProcessor(json["post_processor"])

        var raw: [AddedToken] = [], normalized: [AddedToken] = []
        var maxId = model.pieceCount - 1
        for item in json["added_tokens"] as? [Any] ?? [] {
            guard let d = item as? [String: Any], let id = (d["id"] as? NSNumber)?.intValue,
                  let content = d["content"] as? String, !content.isEmpty else { continue }
            maxId = max(maxId, id)
            let isNormalized = d["normalized"] as? Bool ?? false
            // Normalised added tokens are matched against normalised text, so normalise the pattern too.
            let pattern = isNormalized ? normalizer.apply(content) : content
            guard !pattern.isEmpty else { continue }
            let token = AddedToken(id: Int32(id), content: Array(pattern.utf8),
                                   singleWord: d["single_word"] as? Bool ?? false,
                                   lstrip: d["lstrip"] as? Bool ?? false,
                                   rstrip: d["rstrip"] as? Bool ?? false)
            if isNormalized { normalized.append(token) } else { raw.append(token) }
        }
        rawAddedTokens = raw
        normalizedAddedTokens = normalized
        vocabularySize = max(maxId, (prefixIds + suffixIds).map { Int($0) }.max() ?? 0) + 1
    }

    /// Token ids of `text` including the post-processor's special tokens, truncated (from the right)
    /// so that the result has at most `maxTokens` ids (never fewer than the special tokens).
    func encode(_ text: String, maxTokens: Int) -> [Int32] {
        let budget = max(0, maxTokens - specialTokenCount)
        var ids: [Int32] = []
        ids.reserveCapacity(min(budget, 256))
        let bytes = Array(text.utf8)
        // Pieces are encoded independently, so we can stop as soon as the budget is filled.
        outer: for segment in UnigramTokenizer.split(bytes, on: rawAddedTokens) {
            if ids.count >= budget { break }
            if let id = segment.tokenId { ids.append(id); continue }
            let normalized = normalizer.apply(String(decoding: bytes[segment.range], as: UTF8.self))
            let nbytes = Array(normalized.utf8)
            let parts = normalizedAddedTokens.isEmpty
                ? [Segment(range: 0..<nbytes.count, tokenId: nil)]
                : UnigramTokenizer.split(nbytes, on: normalizedAddedTokens)
            for part in parts {
                if let id = part.tokenId {
                    ids.append(id)
                    if ids.count >= budget { break outer }
                    continue
                }
                let atStart = segment.range.lowerBound == 0 && part.range.lowerBound == 0
                for piece in preTokenizer.pieces(Array(nbytes[part.range]), atOriginalStart: atStart) {
                    model.encode(piece, into: &ids)
                    if ids.count >= budget { break outer }
                }
            }
        }
        if ids.count > budget { ids.removeLast(ids.count - budget) }
        return prefixIds + ids + suffixIds
    }

    // MARK: - Added-token splitting (port of `AddedVocabulary::find_matches`)

    struct Segment {
        var range: Range<Int>
        var tokenId: Int32?
    }

    static func split(_ b: [UInt8], on tokens: [AddedToken]) -> [Segment] {
        if tokens.isEmpty || b.isEmpty { return b.isEmpty ? [] : [Segment(range: 0..<b.count, tokenId: nil)] }
        var firstBytes = [Bool](repeating: false, count: 256)
        for t in tokens { firstBytes[Int(t.content[0])] = true }

        var segments: [Segment] = []
        var startOffset = 0
        var i = 0
        let n = b.count
        while i < n {
            guard firstBytes[Int(b[i])] else { i += 1; continue }
            // Leftmost-longest: the longest token that matches at the leftmost position.
            var best: AddedToken?
            for t in tokens where t.content.count <= n - i && (best == nil || t.content.count > best!.content.count) {
                var match = true
                for (k, c) in t.content.enumerated() where b[i + k] != c { match = false; break }
                if match { best = t }
            }
            guard let token = best else { i += 1; continue }
            var start = i
            var stop = i + token.content.count
            if token.singleWord {
                let wordBefore = start > 0 && isWordScalar(scalar(before: start, in: b))
                let wordAfter = stop < n && isWordScalar(scalar(at: stop, in: b).0)
                if wordBefore || wordAfter { i = stop; continue }   // match consumed but discarded
            }
            if token.lstrip {
                var s = start
                while s > startOffset, scalar(before: s, in: b).properties.isWhitespace { s = previousBoundary(s, in: b) }
                start = max(s, startOffset)
            }
            if token.rstrip {
                while stop < n {
                    let (sc, len) = scalar(at: stop, in: b)
                    guard sc.properties.isWhitespace else { break }
                    stop += len
                }
            }
            if startOffset < start { segments.append(Segment(range: startOffset..<start, tokenId: nil)) }
            segments.append(Segment(range: start..<stop, tokenId: token.id))
            startOffset = stop
            i = stop
        }
        if startOffset < n { segments.append(Segment(range: startOffset..<n, tokenId: nil)) }
        return segments
    }

    private static func previousBoundary(_ i: Int, in b: [UInt8]) -> Int {
        var j = i - 1
        while j > 0 && b[j] & 0xC0 == 0x80 { j -= 1 }
        return j
    }

    private static func scalar(before i: Int, in b: [UInt8]) -> Unicode.Scalar {
        scalar(at: previousBoundary(i, in: b), in: b).0
    }

    /// Decodes the scalar starting at byte `i` (input is valid UTF-8 from a Swift String).
    static func scalar(at i: Int, in b: [UInt8]) -> (Unicode.Scalar, Int) {
        let len = min(utf8SequenceLength(b[i]), b.count - i)
        var v: UInt32
        switch len {
        case 1: v = UInt32(b[i])
        case 2: v = UInt32(b[i] & 0x1F) << 6 | UInt32(b[i + 1] & 0x3F)
        case 3: v = UInt32(b[i] & 0x0F) << 12 | UInt32(b[i + 1] & 0x3F) << 6 | UInt32(b[i + 2] & 0x3F)
        default: v = UInt32(b[i] & 0x07) << 18 | UInt32(b[i + 1] & 0x3F) << 12 | UInt32(b[i + 2] & 0x3F) << 6 | UInt32(b[i + 3] & 0x3F)
        }
        return (Unicode.Scalar(v) ?? "\u{FFFD}", len)
    }

    /// Approximation of the regex class `\w` (alphabetic, marks, decimal digits, connector punctuation).
    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        if p.isAlphabetic || p.isJoinControl { return true }
        switch p.generalCategory {
        case .decimalNumber, .connectorPunctuation, .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    // MARK: - Post-processor

    private static func parsePostProcessor(_ json: Any?) throws -> ([Int32], [Int32]) {
        guard let spec = json as? [String: Any] else { return ([], []) }
        let type = spec["type"] as? String ?? ""
        switch type {
        case "TemplateProcessing":
            let specials = spec["special_tokens"] as? [String: Any] ?? [:]
            var prefix: [Int32] = [], suffix: [Int32] = []
            var seenSequence = false
            for item in spec["single"] as? [Any] ?? [] {
                guard let entry = item as? [String: Any] else { continue }
                if let special = entry["SpecialToken"] as? [String: Any], let name = special["id"] as? String {
                    guard let def = specials[name] as? [String: Any], let ids = def["ids"] as? [Any] else {
                        throw EncoderError.badConfig("post_processor: unknown special token \(name)")
                    }
                    let values = ids.compactMap { ($0 as? NSNumber).map { Int32($0.intValue) } }
                    if seenSequence { suffix += values } else { prefix += values }
                } else if entry["Sequence"] != nil {
                    if seenSequence { throw EncoderError.unsupported("post_processor template with several sequences") }
                    seenSequence = true
                }
            }
            return (prefix, suffix)
        case "RobertaProcessing", "BertProcessing":
            func id(_ key: String) throws -> Int32 {
                guard let pair = spec[key] as? [Any], pair.count == 2, let n = pair[1] as? NSNumber else {
                    throw EncoderError.badConfig("post_processor: missing \(key)")
                }
                return Int32(n.intValue)
            }
            return ([try id("cls")], [try id("sep")])
        case "Sequence":
            for p in spec["processors"] as? [Any] ?? [] {
                let r = try parsePostProcessor(p)
                if !r.0.isEmpty || !r.1.isEmpty { return r }
            }
            return ([], [])
        case "ByteLevel":
            return ([], [])
        default:
            throw EncoderError.unsupported("post_processor '\(type)'")
        }
    }
}

// MARK: - Pre-tokenizer

/// Pre-tokenizers used by SentencePiece-style tokenizer.json files.
struct PreTokenizer {
    enum PrependScheme { case always, first, never }
    enum Step {
        /// Replaces " " by the replacement char ("▁"), optionally prepends it, and splits before each one
        /// (`SplitDelimiterBehavior::MergedWithNext`).
        case metaspace(replacement: [UInt8], prepend: PrependScheme, split: Bool)
        /// Splits on Unicode whitespace, dropping it.
        case whitespaceSplit
    }

    let steps: [Step]

    init(json: Any?) throws {
        var steps: [Step] = []
        try PreTokenizer.collect(json, into: &steps)
        self.steps = steps
    }

    private static func collect(_ json: Any?, into steps: inout [Step]) throws {
        guard let spec = json as? [String: Any] else { return }
        let type = spec["type"] as? String ?? ""
        switch type {
        case "Sequence":
            for p in spec["pretokenizers"] as? [Any] ?? [] { try collect(p, into: &steps) }
        case "Metaspace":
            let replacement = spec["replacement"] as? String ?? "\u{2581}"
            guard replacement.unicodeScalars.count == 1 else {
                throw EncoderError.badConfig("Metaspace replacement must be one character")
            }
            // Legacy files use add_prefix_space; newer ones prepend_scheme (default "always") and split (default true).
            var scheme = PrependScheme.always
            switch spec["prepend_scheme"] as? String {
            case "first": scheme = .first
            case "never": scheme = .never
            default: break
            }
            if let add = spec["add_prefix_space"] as? Bool, !add { scheme = .never }
            steps.append(.metaspace(replacement: Array(replacement.utf8), prepend: scheme, split: spec["split"] as? Bool ?? true))
        case "WhitespaceSplit":
            steps.append(.whitespaceSplit)
        default:
            throw EncoderError.unsupported("pre_tokenizer '\(type)'")
        }
    }

    /// Splits one normalised segment into the pieces handed to the model.
    func pieces(_ text: [UInt8], atOriginalStart: Bool) -> [[UInt8]] {
        var current: [(bytes: [UInt8], atStart: Bool)] = text.isEmpty ? [] : [(text, atOriginalStart)]
        for step in steps {
            var next: [(bytes: [UInt8], atStart: Bool)] = []
            for (bytes, atStart) in current {
                switch step {
                case .whitespaceSplit:
                    var pieceStart = -1
                    var i = 0
                    while i <= bytes.count {
                        var isSpace = true
                        var len = 1
                        if i < bytes.count {
                            let (sc, l) = UnigramTokenizer.scalar(at: i, in: bytes)
                            isSpace = sc.properties.isWhitespace
                            len = l
                        }
                        if isSpace {
                            if pieceStart >= 0 {
                                next.append((Array(bytes[pieceStart..<i]), atStart && pieceStart == 0))
                                pieceStart = -1
                            }
                        } else if pieceStart < 0 {
                            pieceStart = i
                        }
                        i += len
                    }
                case .metaspace(let rep, let prepend, let split):
                    var m: [UInt8] = []
                    m.reserveCapacity(bytes.count + 8)
                    for c in bytes { if c == 0x20 { m.append(contentsOf: rep) } else { m.append(c) } }
                    if m.isEmpty { continue }
                    if prepend == .always || (prepend == .first && atStart), !m.starts(with: rep) {
                        m.insert(contentsOf: rep, at: 0)
                    }
                    guard split else { next.append((m, atStart)); continue }
                    // A new piece starts at every occurrence of the replacement character.
                    var pieceStart = 0
                    var i = 1
                    while i < m.count {
                        if m[i] == rep[0], i + rep.count <= m.count, m[i..<(i + rep.count)].elementsEqual(rep) {
                            next.append((Array(m[pieceStart..<i]), atStart && pieceStart == 0))
                            pieceStart = i
                            i += rep.count
                        } else {
                            i += 1
                        }
                    }
                    next.append((Array(m[pieceStart...]), atStart && pieceStart == 0))
                }
            }
            current = next
        }
        return current.map { $0.bytes }
    }
}

// MARK: - Unigram model

/// Unigram language model: vocabulary pieces with log-probability scores, searched with a byte trie.
final class UnigramModel {
    /// Score assigned to an unknown character: `min_score - 10` (HF `K_UNK_PENALTY`).
    private let unkScore: Double
    private let unkId: Int32?
    private let scores: [Double]
    private let trie: PieceTrie
    /// `<0x00>`…`<0xFF>` ids when `byte_fallback` is enabled and all 256 byte pieces exist.
    private let byteFallbackIds: [Int32]?
    let pieceCount: Int

    var approximateMemoryBytes: Int { scores.count * 8 + trie.approximateMemoryBytes }

    init(json: [String: Any]) throws {
        guard let vocab = json["vocab"] as? [Any], !vocab.isEmpty else {
            throw EncoderError.badConfig("tokenizer.json: Unigram model without vocabulary")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(vocab.count * 10)
        var starts: [Int32] = []
        starts.reserveCapacity(vocab.count + 1)
        var scores: [Double] = []
        scores.reserveCapacity(vocab.count)
        var byteIds = [Int32](repeating: -1, count: 256)
        let wantBytes = json["byte_fallback"] as? Bool ?? false
        for (index, entry) in vocab.enumerated() {
            guard let pair = entry as? [Any], pair.count >= 2, let piece = pair[0] as? String,
                  let score = pair[1] as? NSNumber else {
                throw EncoderError.badConfig("tokenizer.json: malformed vocabulary entry \(index)")
            }
            starts.append(Int32(bytes.count))
            bytes.append(contentsOf: piece.utf8)
            scores.append(score.doubleValue)
            if wantBytes, piece.utf8.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let v = UInt8(piece.dropFirst(3).prefix(2), radix: 16) {
                byteIds[Int(v)] = Int32(index)
            }
        }
        starts.append(Int32(bytes.count))

        if let unk = (json["unk_id"] as? NSNumber)?.intValue {
            guard unk >= 0 && unk < scores.count else { throw EncoderError.badConfig("tokenizer.json: unk_id out of range") }
            unkId = Int32(unk)
        } else {
            unkId = nil
        }
        unkScore = (scores.min() ?? 0) - 10
        byteFallbackIds = wantBytes && !byteIds.contains(-1) ? byteIds : nil
        pieceCount = scores.count
        self.scores = scores
        trie = PieceTrie(bytes: bytes, starts: starts)
    }

    /// Viterbi segmentation of one pre-tokenized piece (port of `Unigram::encode_optimized` + `tokenize`).
    /// Ties keep the first candidate found (earlier start, then shorter piece), exactly like the Rust code.
    func encode(_ s: [UInt8], into out: inout [Int32]) {
        let n = s.count
        guard n > 0 else { return }
        var bestScore = [Double](repeating: 0, count: n + 1)
        var bestStart = [Int](repeating: -1, count: n + 1)
        var bestId = [Int32](repeating: -1, count: n + 1)

        var pos = 0
        while pos < n {
            let charLen = min(utf8SequenceLength(s[pos]), n - pos)
            let base = bestScore[pos]
            var hasSingleCharPiece = false
            var node = trie.rootChild(s[pos])
            var end = pos + 1
            while node >= 0 {
                let piece = trie.value(node)
                if piece >= 0 {
                    let candidate = scores[Int(piece)] + base
                    if bestStart[end] < 0 || candidate > bestScore[end] {
                        bestScore[end] = candidate
                        bestStart[end] = pos
                        bestId[end] = piece
                    }
                    if end - pos == charLen { hasSingleCharPiece = true }
                }
                if end >= n { break }
                node = trie.child(node, s[end])
                end += 1
            }
            if !hasSingleCharPiece, let unk = unkId {
                let target = pos + charLen
                let candidate = unkScore + base
                if bestStart[target] < 0 || candidate > bestScore[target] {
                    bestScore[target] = candidate
                    bestStart[target] = pos
                    bestId[target] = unk
                }
            }
            pos += charLen
        }

        // Backtrack; consecutive unknown characters are fused into a single token.
        var reversed: [Int32] = []
        var unkRunEnd = -1, unkRunStart = -1
        func flushUnknownRun() {
            guard unkRunEnd >= 0, let unk = unkId else { return }
            if let byteIds = byteFallbackIds {
                for i in stride(from: unkRunEnd - 1, through: unkRunStart, by: -1) { reversed.append(byteIds[Int(s[i])]) }
            } else {
                reversed.append(unk)
            }
            unkRunEnd = -1
        }
        var end = n
        while end > 0 {
            let start = bestStart[end]
            guard start >= 0 else { break }   // unreachable without an unk id
            let id = bestId[end]
            if let unk = unkId, id == unk {
                if unkRunEnd < 0 { unkRunEnd = end }
                unkRunStart = start
            } else {
                flushUnknownRun()
                reversed.append(id)
            }
            end = start
        }
        flushUnknownRun()
        out.append(contentsOf: reversed.reversed())
    }
}

/// Byte-level trie over the vocabulary. Children of a node are stored contiguously, sorted by label,
/// so a lookup is a binary search; the root uses a direct 256-entry table.
struct PieceTrie {
    private var labels: [UInt8] = [0]
    private var values: [Int32] = [-1]        // piece id ending at this node, or -1
    private var firstChild: [Int32] = [0]
    private var childCount: [UInt16] = [0]
    private var root = [Int32](repeating: -1, count: 256)

    var nodeCount: Int { labels.count }
    var approximateMemoryBytes: Int { labels.count * 11 + root.count * 4 }

    /// `bytes[starts[i] ..< starts[i+1]]` is the UTF-8 of piece `i` (its id).
    init(bytes: [UInt8], starts: [Int32]) {
        let n = starts.count - 1
        guard n > 0 else { return }
        var order = [Int32](0..<Int32(n))
        bytes.withUnsafeBufferPointer { b in
            starts.withUnsafeBufferPointer { st in
                guard let base = b.baseAddress else { return }
                // Lexicographic byte order; equal strings keep id order so the *last* duplicate wins
                // (as with the HashMap in the Rust implementation).
                order.sort { x, y in
                    let xs = Int(st[Int(x)]), xl = Int(st[Int(x) + 1]) - xs
                    let ys = Int(st[Int(y)]), yl = Int(st[Int(y) + 1]) - ys
                    let c = memcmp(base + xs, base + ys, min(xl, yl))
                    if c != 0 { return c < 0 }
                    if xl != yl { return xl < yl }
                    return x < y
                }
            }
        }
        @inline(__always) func length(_ p: Int32) -> Int { Int(starts[Int(p) + 1] - starts[Int(p)]) }
        @inline(__always) func byte(_ p: Int32, _ depth: Int) -> UInt8 { bytes[Int(starts[Int(p)]) + depth] }

        labels.reserveCapacity(n * 4)
        values.reserveCapacity(n * 4)
        firstChild.reserveCapacity(n * 4)
        childCount.reserveCapacity(n * 4)
        // Depth-first construction; all children of a node are allocated together (contiguous).
        var stack: [(node: Int32, lo: Int32, hi: Int32, depth: Int32)] = [(0, 0, Int32(n), 0)]
        while let item = stack.popLast() {
            var i = Int(item.lo)
            let hi = Int(item.hi), depth = Int(item.depth), node = Int(item.node)
            while i < hi && length(order[i]) == depth { values[node] = order[i]; i += 1 }
            let first = labels.count
            var count = 0
            while i < hi {
                let label = byte(order[i], depth)
                var j = i + 1
                while j < hi && byte(order[j], depth) == label { j += 1 }
                labels.append(label)
                values.append(-1)
                firstChild.append(0)
                childCount.append(0)
                stack.append((Int32(labels.count - 1), Int32(i), Int32(j), Int32(depth + 1)))
                count += 1
                i = j
            }
            firstChild[node] = Int32(first)
            childCount[node] = UInt16(count)
        }
        for c in 0..<Int(childCount[0]) { root[Int(labels[Int(firstChild[0]) + c])] = firstChild[0] + Int32(c) }
    }

    @inline(__always) func rootChild(_ byte: UInt8) -> Int32 { root[Int(byte)] }
    @inline(__always) func value(_ node: Int32) -> Int32 { values[Int(node)] }

    @inline(__always)
    func child(_ node: Int32, _ byte: UInt8) -> Int32 {
        var lo = Int(firstChild[Int(node)])
        var hi = lo + Int(childCount[Int(node)])
        while lo < hi {
            let mid = (lo + hi) >> 1
            let l = labels[mid]
            if l < byte { lo = mid + 1 } else if l > byte { hi = mid } else { return Int32(mid) }
        }
        return -1
    }
}
