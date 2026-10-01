import CoreGraphics
import Foundation

/// A piece of recognised text and its box in image pixels (top-left origin).
public struct OCRWord: Equatable {
    public enum Engine: UInt8 { case vision, tesseract }
    public var text: String
    public var box: CGRect
    /// 0…1.
    public var confidence: Float
    public var engine: Engine
    /// Tesseract's layout block (-1 for Vision segments).
    public var block: Int
    /// Tesseract's line, numbered in its reading order (-1 for Vision segments).
    public var line: Int

    public init(text: String, box: CGRect, confidence: Float, engine: Engine, block: Int = -1, line: Int = -1) {
        self.text = text; self.box = box; self.confidence = confidence; self.engine = engine; self.block = block; self.line = line
    }
}

/// One line of recognised text, its words in reading order.
public struct OCRLine: Equatable {
    public var text: String
    public var box: CGRect
    public var confidence: Float
    /// Layout block the line belongs to: the lines of one sidebar or paragraph share a block (-1: unknown).
    public var block: Int
    public var wordCount: Int

    public init(text: String, box: CGRect, confidence: Float, block: Int, wordCount: Int) {
        self.text = text; self.box = box; self.confidence = confidence; self.block = block; self.wordCount = wordCount
    }
}

/// One line Vision read, with the box of each of its words (Vision's own split; empty when unknown).
public struct VisionLine {
    public var text: String
    public var box: CGRect
    public var confidence: Float
    public var words: [(text: String, box: CGRect)]

    public init(text: String, box: CGRect, confidence: Float, words: [(text: String, box: CGRect)] = []) {
        self.text = text; self.box = box; self.confidence = confidence; self.words = words
    }
}

/// Combines the two OCR engines. Apple's Vision has no Hebrew, so Tesseract's Hebrew model reads the page; Vision reads
/// Latin script far better than Tesseract's Hebrew model (which forces Latin text into Hebrew letters). Vision returns
/// confident text only where it can read it — elsewhere nothing, or noise at ~0.3–0.5 — so each confident Vision
/// segment replaces the Tesseract words under it.
public enum OCRFusion {
    /// Vision segments below this are noise read off a script Vision does not know (it reports ~1.0 on Latin text).
    public static let minVisionConfidence: Float = 0.8
    /// Tesseract words below this are mostly glyphs of another script forced into Hebrew letters.
    public static let minTesseractConfidence: Float = 0.5
    /// Under a Vision segment a Tesseract word survives only if it is confidently Hebrew: the Hebrew model's reading of
    /// Latin text scores up to ~0.76.
    public static let minHebrewUnderLatin: Float = 0.85

    /// Word rows (level 5) of Tesseract's TSV output.
    public static func parseTesseractTSV(_ tsv: String) -> [OCRWord] {
        var words: [OCRWord] = []
        var lineIDs: [String: Int] = [:]
        for row in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = row.split(separator: "\t", maxSplits: 11, omittingEmptySubsequences: false)
            guard f.count == 12, f[0] == "5", let block = Int(f[2]), let left = Double(f[6]), let top = Double(f[7]),
                  let width = Double(f[8]), let height = Double(f[9]), let conf = Float(f[10]) else { continue }
            let text = clean(String(f[11]))
            guard !text.isEmpty else { continue }
            let lineKey = "\(f[2]).\(f[3]).\(f[4])"
            let line: Int
            if let l = lineIDs[lineKey] { line = l } else { line = lineIDs.count; lineIDs[lineKey] = line }
            words.append(OCRWord(text: text, box: CGRect(x: left, y: top, width: width, height: height),
                                 confidence: max(0, min(1, conf / 100)), engine: .tesseract, block: block, line: line))
        }
        return words
    }

    /// Bidi controls (Tesseract wraps Latin runs in them) and other invisible marks.
    private static let invisibles: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D,
                                                 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]

    public static func clean(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars where !invisibles.contains(u.value) { scalars.append(u) }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isHebrew(_ u: Unicode.Scalar) -> Bool { (0x05D0...0x05EA).contains(u.value) || (0xFB1D...0xFB4F).contains(u.value) }
    static func isLatin(_ u: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) || (0xC0...0x24F).contains(u.value)
    }

    public static func hebrewLetterCount(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 + (isHebrew($1) ? 1 : 0) } }
    static func latinLetterCount(_ s: String) -> Int { s.unicodeScalars.reduce(0) { $0 + (isLatin($1) ? 1 : 0) } }

    /// A word the Hebrew model is sure of (two-letter words need more). Within a Hebrew line it wins over whatever Vision
    /// read in its place: Vision turns bold Hebrew into confident Latin-looking noise ("vonnx", "pınıka", "OI").
    static func isConfidentHebrew(_ w: OCRWord) -> Bool {
        let letters = hebrewLetterCount(w.text)
        return letters >= 3 ? w.confidence >= minHebrewUnderLatin : letters == 2 && w.confidence >= 0.92
    }

    /// Tesseract words lying (mostly) inside `box`.
    static func indices(of tesseract: [OCRWord], under box: CGRect, dx: CGFloat) -> [Int] {
        let area = box.insetBy(dx: -dx * box.height, dy: -0.2 * box.height)
        return tesseract.indices.filter { i in
            let inter = area.intersection(tesseract[i].box)
            return !inter.isNull && inter.width * inter.height >= 0.5 * tesseract[i].box.width * tesseract[i].box.height
        }
    }

    /// Merges both engines' words into lines in reading order (words right-to-left on lines where Hebrew dominates).
    public static func merge(tesseract: [OCRWord], vision: [VisionLine]) -> [OCRLine] {
        var removed = Set<Int>()
        var latin: [OCRWord] = []
        for seg in vision where seg.confidence >= minVisionConfidence
            && seg.text.unicodeScalars.contains(where: { isLatin($0) || CharacterSet.decimalDigits.contains($0) }) {
            // Latin text takes ~0.35–0.5 line heights per character: a much wider box also spans text Vision skipped
            // (it cannot split Hebrew off the Latin words next to it), so confident Hebrew words under it are kept
            let overWide = seg.box.width > 0.8 * seg.box.height * CGFloat(max(seg.text.count, 1))
            if !overWide && !seg.words.isEmpty {
                // Which words of the line lie on confident Hebrew? Few of many: a Latin line, those are the Hebrew model's
                // misreadings of Latin words ("for" → "זסז"). Otherwise a Hebrew line Vision partly turned into noise:
                // word by word, confident Hebrew wins
                let onHebrew = seg.words.map { w in indices(of: tesseract, under: w.box, dx: 0.15).contains { isConfidentHebrew(tesseract[$0]) } }
                let hebrewCount = onHebrew.filter { $0 }.count
                if hebrewCount == 0 || (seg.words.count >= 4 && Double(hebrewCount) <= 0.25 * Double(seg.words.count)) {
                    removed.formUnion(indices(of: tesseract, under: seg.box, dx: 0.3))
                    latin.append(OCRWord(text: seg.text, box: seg.box, confidence: seg.confidence, engine: .vision))
                } else {
                    for (w, hebrew) in zip(seg.words, onHebrew) where !hebrew {
                        removed.formUnion(indices(of: tesseract, under: w.box, dx: 0.15))
                        latin.append(OCRWord(text: w.text, box: w.box, confidence: seg.confidence, engine: .vision))
                    }
                }
                continue
            }
            var box = seg.box
            var hebrewSpans: [(lo: CGFloat, hi: CGFloat)] = []
            for i in indices(of: tesseract, under: seg.box, dx: 0.3) {
                if overWide && isConfidentHebrew(tesseract[i]) {
                    hebrewSpans.append((tesseract[i].box.minX, tesseract[i].box.maxX))
                } else {
                    removed.insert(i)
                }
            }
            if !hebrewSpans.isEmpty {
                // the Latin text is in the widest stretch of the box the Hebrew words leave free
                var gaps: [(lo: CGFloat, hi: CGFloat)] = []
                var cursor = box.minX
                for s in hebrewSpans.sorted(by: { $0.lo < $1.lo }) {
                    if s.lo > cursor { gaps.append((cursor, s.lo)) }
                    cursor = max(cursor, s.hi)
                }
                if box.maxX > cursor { gaps.append((cursor, box.maxX)) }
                guard let widest = gaps.max(by: { $0.hi - $0.lo < $1.hi - $1.lo }), widest.hi - widest.lo >= 0.5 * box.height else { continue }
                box = CGRect(x: widest.lo, y: box.minY, width: widest.hi - widest.lo, height: box.height)
            }
            latin.append(OCRWord(text: seg.text, box: box, confidence: seg.confidence, engine: .vision))
        }

        var lines: [Int: [OCRWord]] = [:]
        for (i, w) in tesseract.enumerated() where w.confidence >= minTesseractConfidence && !removed.contains(i) {
            lines[w.line, default: []].append(w)
        }
        var lineBoxes: [Int: CGRect] = [:]
        var lineBlocks: [Int: Int] = [:]
        for w in tesseract {
            lineBoxes[w.line] = lineBoxes[w.line].map { $0.union(w.box) } ?? w.box
            lineBlocks[w.line] = w.block
        }
        // a Vision segment joins the Tesseract line it shares most of its height with, or becomes a line of its own
        var nextLine = (lineBoxes.keys.max() ?? -1) + 1
        for v in latin {
            var best: (line: Int, overlap: CGFloat)?
            for (l, box) in lineBoxes {
                let vOverlap = min(box.maxY, v.box.maxY) - max(box.minY, v.box.minY)
                let hGap = max(box.minX, v.box.minX) - min(box.maxX, v.box.maxX)
                guard hGap < v.box.height, vOverlap >= 0.5 * min(box.height, v.box.height) else { continue }
                if best == nil || vOverlap > best!.overlap { best = (l, vOverlap) }
            }
            if let b = best {
                var seg = v
                seg.block = lineBlocks[b.line] ?? -1
                lines[b.line, default: []].append(seg)
            } else {
                lines[nextLine] = [v]
                nextLine += 1
            }
        }

        var out: [(order: Double, line: OCRLine)] = []
        for (id, words) in lines where !words.isEmpty {
            // a line is right-to-left when it has at least as many Hebrew words as Latin ones (letters would let long
            // English words turn a Hebrew sentence around)
            // (fragments do not vote: Hebrew prefixes glued to English words come out as "l", "ll", "n")
            var hebrew = 0, latinWords = 0
            for token in words.flatMap({ $0.text.split(separator: " ") }).map(String.init) {
                if hebrewLetterCount(token) >= 2 { hebrew += 1 } else if hebrewLetterCount(token) == 0, latinLetterCount(token) >= 3 { latinWords += 1 }
            }
            let rtl = hebrew > 0 && hebrew >= latinWords
            let ordered = words.sorted { rtl ? $0.box.maxX > $1.box.maxX : $0.box.minX < $1.box.minX }
            let box = ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            let line = OCRLine(text: ordered.map(\.text).joined(separator: " "), box: box,
                               confidence: ordered.reduce(Float(0)) { $0 + $1.confidence } / Float(ordered.count),
                               block: ordered.first { $0.block >= 0 }?.block ?? -1,
                               wordCount: ordered.reduce(0) { $0 + $1.text.split(separator: " ").count })
            if lineBoxes[id] != nil {
                out.append((Double(id), line))
            } else {
                // Tesseract numbers lines in its reading order (one column after another): a line only Vision read
                // follows the nearest Tesseract line above it in the same column
                let above = lineBoxes.filter { _, b in b.midY <= box.midY && min(b.maxX, box.maxX) > max(b.minX, box.minX) }
                    .max { $0.value.midY < $1.value.midY }
                out.append((Double(above?.key ?? -1) + 0.5 + Double(box.midY) * 1e-7, line))
            }
        }
        return out.sorted { $0.order < $1.order }.map(\.line)
    }

    /// Where the Hebrew model probably met Latin text it cannot read and Vision did not read it either (Vision often
    /// misses an English word inside a Hebrew line): runs of a line's words that hold no Hebrew letter, with at least
    /// one low-confidence word (the Hebrew model's garbage), that no confident Vision word covers — each worth a second,
    /// closer look by Vision. ("code review" can come out as "6006" + garbage: the run takes both.)
    public static func latinCandidates(tesseract: [OCRWord], vision: [VisionLine], limit: Int = 24) -> [CGRect] {
        let covered = vision.filter { $0.confidence >= minVisionConfidence }.flatMap { seg in seg.words.isEmpty ? [seg.box] : seg.words.map(\.box) }
        var boxes: [CGRect] = []
        for words in Dictionary(grouping: tesseract, by: \.line).values {
            var run: (box: CGRect, weak: Bool)?
            func close() {
                if let r = run, r.weak { boxes.append(r.box) }
                run = nil
            }
            for w in words.sorted(by: { $0.box.minX < $1.box.minX }) {
                let latinish = hebrewLetterCount(w.text) == 0 && w.text.contains { $0.isLetter || $0.isNumber }
                // the Hebrew model turns capitals into digits ("OCR" → "068", "ה-OCR" → "ה-008"): digits deserve a look too
                // (a real number just comes back as the same number)
                let digits = w.text.filter(\.isNumber).count >= 2 && hebrewLetterCount(w.text) <= 1
                let weak = (w.confidence < minTesseractConfidence && w.text.count >= 3 && w.text.contains { $0.isLetter || $0.isNumber }) || digits
                guard (weak || latinish), !covered.contains(where: { $0.intersects(w.box) }) else { close(); continue }
                if let r = run, w.box.minX - r.box.maxX < w.box.height {
                    run = (r.box.union(w.box), r.weak || weak)
                } else {
                    close()
                    run = (w.box, weak)
                }
            }
            close()
        }
        return Array(boxes.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }.prefix(limit))
    }
}
