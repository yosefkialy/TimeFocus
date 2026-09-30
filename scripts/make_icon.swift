// Draws the TimeFocus app icon (a focus "scope" made of neural-network nodes) and writes an .iconset.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: 824/1024 body with rounded corners
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.5, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.25, green: 0.24, blue: 0.78, alpha: 1),
        CGColor(red: 0.33, green: 0.35, blue: 0.93, alpha: 1),
        CGColor(red: 0.08, green: 0.67, blue: 0.64, alpha: 1),
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    let c = CGPoint(x: s / 2, y: s / 2)
    // neural nodes on two rings, connected
    var nodes: [CGPoint] = []
    for (ring, count, phase) in [(0.30, 9, 0.2), (0.19, 6, 0.9)] {
        for i in 0..<count {
            let a = Double(i) / Double(count) * 2 * .pi + phase
            nodes.append(CGPoint(x: c.x + CGFloat(cos(a) * ring) * s, y: c.y + CGFloat(sin(a) * ring) * s))
        }
    }
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(s * 0.006)
    for i in 0..<9 {
        for j in 9..<15 where (i + j) % 3 == 0 {
            ctx.move(to: nodes[i]); ctx.addLine(to: nodes[j])
        }
        ctx.move(to: nodes[i]); ctx.addLine(to: nodes[(i + 1) % 9])
    }
    ctx.strokePath()
    for (k, n) in nodes.enumerated() {
        let r = s * (k < 9 ? 0.018 : 0.022)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: k < 9 ? 0.55 : 0.8))
        ctx.fillEllipse(in: CGRect(x: n.x - r, y: n.y - r, width: 2 * r, height: 2 * r))
    }
    // focus rings
    for (r, w, a) in [(0.36, 0.022, 0.9), (0.115, 0.03, 1.0)] {
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: a))
        ctx.setLineWidth(s * w)
        ctx.strokeEllipse(in: CGRect(x: c.x - s * r, y: c.y - s * r, width: 2 * s * r, height: 2 * s * r))
    }
    // cross-hair ticks
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.024)
    for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
        ctx.move(to: CGPoint(x: c.x + CGFloat(dx) * s * 0.30, y: c.y + CGFloat(dy) * s * 0.30))
        ctx.addLine(to: CGPoint(x: c.x + CGFloat(dx) * s * 0.42, y: c.y + CGFloat(dy) * s * 0.42))
    }
    ctx.strokePath()
    ctx.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.3, alpha: 1))
    let dot = s * 0.05
    ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot))
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written to \(out)")
