import AppKit
import CoreGraphics

/// Screen-like text images for the OCR tests: lines drawn with the system font (right-to-left lines laid out as
/// AppKit lays them out on screen), at 2 pixels per point like a Retina capture.
enum OCRFixtures {
    struct Line {
        var text: String
        var size: CGFloat
        var bold = false
    }

    static func render(_ lines: [Line], width: CGFloat = 1100, scale: CGFloat = 2, dark: Bool = false) -> CGImage {
        let heights = lines.map { $0.size * 1.7 }
        let height = heights.reduce(40, +)
        let w = Int(width * scale), h = Int(height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(dark ? CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        var y = height - 20
        for (line, lh) in zip(lines, heights) {
            y -= lh
            let para = NSMutableParagraphStyle()
            para.baseWritingDirection = .natural
            para.alignment = .natural
            let font = line.bold ? NSFont.boldSystemFont(ofSize: line.size) : NSFont.systemFont(ofSize: line.size)
            NSAttributedString(string: line.text, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1),
            ]).draw(in: CGRect(x: 20, y: y, width: width - 40, height: lh))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func load(_ path: String) -> CGImage? {
        NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Share of `expected`'s words (2+ letters) found among the words of `text`.
    static func wordRecall(_ expected: String, in text: String) -> Double {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        }
        let want = words(expected)
        let have = Set(words(text))
        guard !want.isEmpty else { return 1 }
        return Double(want.filter { have.contains($0) }.count) / Double(want.count)
    }
}
