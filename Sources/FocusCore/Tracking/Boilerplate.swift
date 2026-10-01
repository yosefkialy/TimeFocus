import CoreGraphics
import Foundation
import FocusML

/// Layout rules for text read off a screenshot: the text that frames the content — side columns of short lines
/// (navigation, tables of contents, channel lists) and short-line strips along the very top and bottom (tab strips,
/// toolbars, status bars) — says nothing about what the window is used for.
public enum OCRLayout {
    /// A block whose lines average fewer words than this is a menu, a list of links or a heading, not running text.
    static let proseWords = 5.0

    public static func contentLines(_ lines: [OCRLine], imageSize: CGSize) -> [OCRLine] {
        guard imageSize.width > 0, imageSize.height > 0 else { return lines }
        struct Block { var box: CGRect; var lines = 0; var words = 0; var chars = 0 }
        var blocks: [Int: Block] = [:]
        // lines Tesseract did not place in a block (Vision-only lines) are blocks of their own
        let keys = lines.enumerated().map { i, l in l.block >= 0 ? l.block : -2 - i }
        for (l, k) in zip(lines, keys) {
            var b = blocks[k] ?? Block(box: l.box)
            b.box = b.box.union(l.box)
            b.lines += 1
            b.words += l.wordCount
            b.chars += l.text.count
            blocks[k] = b
        }
        func isProse(_ b: Block) -> Bool { Double(b.words) / Double(max(b.lines, 1)) >= proseWords }
        let w = imageSize.width, h = imageSize.height
        // a single line, or short lines, along the very top or bottom: a menu bar, a toolbar, a footer
        func isEdgeStrip(_ b: Block) -> Bool { (b.lines == 1 || !isProse(b)) && (b.box.maxY <= 0.06 * h || b.box.minY >= 0.94 * h) }
        let prose = blocks.values.filter { isProse($0) && !isEdgeStrip($0) }
        guard prose.reduce(0, { $0 + $1.chars }) >= 120 else { return lines } // nothing to anchor on (code, spreadsheets…)

        // the main column: the prose block with the most text, preferring the middle of the window, widened by the
        // paragraphs above and below it
        func centrality(_ r: CGRect) -> Double { max(0.25, 1 - abs(Double(r.midX - w / 2)) / Double(w / 2)) }
        guard let anchor = prose.max(by: { Double($0.chars) * centrality($0.box) < Double($1.chars) * centrality($1.box) }) else {
            return lines
        }
        var column = (lo: anchor.box.minX, hi: anchor.box.maxX)
        func overlap(_ r: CGRect) -> CGFloat { max(0, min(r.maxX, column.hi) - max(r.minX, column.lo)) }
        for b in prose where b.lines >= 2 && overlap(b.box) >= 0.5 * b.box.width {
            column = (min(column.lo, b.box.minX), max(column.hi, b.box.maxX))
        }
        var dropped = Set<Int>()
        for (k, b) in blocks {
            // a column beside the main one that is not running text: navigation, a table of contents, a channel list
            let beside = !isProse(b) && overlap(b.box) < 0.25 * b.box.width
            if beside || isEdgeStrip(b) { dropped.insert(k) }
        }
        return zip(lines, keys).filter { !dropped.contains($0.1) }.map(\.0)
    }
}

/// Learns the lines an app or a website shows in most of its windows — menus, navigation, bookmarks, toolbars,
/// footers, cookie notices — and drops them: they are the same whatever the window is used for. A line is boilerplate
/// once it has appeared in at least `minWindows` of the template's recent windows and in at least `minShare` of them,
/// so text shared by only some of a site's pages (a course name on that course's pages) is kept.
///
/// Owned by one queue (not thread-safe). Bounded: a ring of `recentWindows` windows per template, `maxLines` lines per
/// template, `maxTemplates` templates.
public final class BoilerplateFilter {
    public let minWindows: Int
    public let minShare: Double
    public let recentWindows: Int
    let maxLines: Int
    let maxTemplates: Int

    struct Template: Codable {
        /// Window ids in ring slots (0 = free slot).
        var windows: [UInt64]
        var nextSlot = 0
        /// Line hash → bit mask of the ring slots of the windows it appeared in.
        var lines: [UInt64: UInt32] = [:]
        var lastUsed: Double
    }
    private var templates: [String: Template] = [:]

    public init(minWindows: Int = 3, minShare: Double = 0.6, recentWindows: Int = 24, maxLines: Int = 1500, maxTemplates: Int = 64) {
        self.minWindows = minWindows
        self.minShare = minShare
        self.recentWindows = min(max(recentWindows, 2), 32) // slots are bits of a UInt32
        self.maxLines = maxLines
        self.maxTemplates = maxTemplates
    }

    /// Lines are compared without case, digits (counters, dates) and punctuation.
    static func lineKey(_ line: String) -> UInt64? {
        var out = String.UnicodeScalarView()
        var space = false
        for u in line.lowercased().unicodeScalars {
            if CharacterSet.decimalDigits.contains(u) {
                if out.last != "0" { out.append("0") }
                space = false
            } else if CharacterSet.letters.contains(u) {
                if space, !out.isEmpty { out.append(" ") }
                out.append(u)
                space = false
            } else {
                space = true
            }
        }
        guard out.count >= 2 else { return nil }
        return fnv1a64(String(out), salt: 0xB0B)
    }

    /// Records the lines seen in `window` (any stable id of the window, e.g. its context key) of `template` (an app,
    /// or app + website) and returns the ones that are not boilerplate, in their original order.
    public func filter(_ lines: [String], template: String, window: String, now: Date = Date()) -> [String] {
        let windowID = max(1, fnv1a64(window, salt: 0x51D))
        var t = templates[template] ?? Template(windows: [UInt64](repeating: 0, count: recentWindows), lastUsed: 0)
        t.lastUsed = now.timeIntervalSince1970
        let slot: Int
        if let s = t.windows.firstIndex(of: windowID) {
            slot = s
        } else {
            slot = t.nextSlot
            t.nextSlot = (t.nextSlot + 1) % recentWindows
            if t.windows[slot] != 0 { // the oldest window leaves the ring
                let clear = ~(UInt32(1) << UInt32(slot))
                for (k, mask) in t.lines {
                    let m = mask & clear
                    if m == 0 { t.lines.removeValue(forKey: k) } else { t.lines[k] = m }
                }
            }
            t.windows[slot] = windowID
        }
        let bit = UInt32(1) << UInt32(slot)
        let keys = lines.map(Self.lineKey)
        for k in keys.compactMap({ $0 }) { t.lines[k, default: 0] |= bit }
        if t.lines.count > maxLines {
            // lines seen in a single window are the bulk and the least useful to remember
            t.lines = t.lines.filter { $0.value.nonzeroBitCount > 1 }
            if t.lines.count > maxLines { t.lines.removeAll() }
        }
        let windowsSeen = t.windows.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        let needed = max(minWindows, Int((minShare * Double(windowsSeen)).rounded(.up)))
        let kept = zip(lines, keys).filter { _, k in
            guard let k, let mask = t.lines[k] else { return true }
            return mask.nonzeroBitCount < needed
        }.map(\.0)
        templates[template] = t
        if templates.count > maxTemplates, let oldest = templates.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            templates.removeValue(forKey: oldest)
        }
        return kept
    }

    /// Whether a line would currently be dropped for a template (without recording anything).
    public func isBoilerplate(_ line: String, template: String) -> Bool {
        guard let t = templates[template], let k = Self.lineKey(line), let mask = t.lines[k] else { return false }
        let windowsSeen = t.windows.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        return mask.nonzeroBitCount >= max(minWindows, Int((minShare * Double(windowsSeen)).rounded(.up)))
    }

    public func reset() { templates.removeAll() }

    // MARK: persistence (only lines seen in several windows are worth keeping across launches)

    public struct State: Codable {
        var templates: [String: Template]
    }

    public var state: State {
        State(templates: templates.mapValues { t in
            var t = t
            t.lines = t.lines.filter { $0.value.nonzeroBitCount > 1 }
            return t
        })
    }

    public func restore(_ s: State) {
        templates = s.templates.filter { $0.value.windows.count == recentWindows }
    }
}
