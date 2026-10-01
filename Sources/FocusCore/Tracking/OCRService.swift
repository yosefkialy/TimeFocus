import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// What OCR read in a window's content area.
public struct OCRReading {
    public var lines: [String]
    public var usedTesseract: Bool
    public var seconds: Double
}

/// On-device OCR of the content area of the focused window (ScreenCaptureKit + Vision + Tesseract). Optional — needs
/// the Screen Recording permission. The image is never stored; only recognised text is kept.
///
/// Vision reads Latin script; Hebrew (which Vision does not support) is read by Tesseract's Hebrew model when the
/// user has installed it, and the two are merged word by word (`OCRFusion`). Only the window's content area is read
/// when the caller knows it (`ContentRegion`); otherwise side columns and edge strips of short lines are dropped by
/// layout (`OCRLayout`).
public final class OCRService {
    private var busy = false
    private let lock = NSLock()
    private let paths: AppPaths
    /// Fingerprint of the last image read per window: an unchanged screen is not read again.
    private var lastPrint: [String: UInt64] = [:]

    init(paths: AppPaths) { self.paths = paths }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Front-most on-screen window number of `pid` (public CGWindowList API; no permission needed for ids).
    static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let num = w[kCGWindowNumber as String] as? UInt32 else { continue }
            return CGWindowID(num)
        }
        return nil
    }

    /// Latin-script languages Vision should read: English plus the user's own Latin-script languages that Vision knows.
    /// (On macOS 27 Vision may honour only the first language of a list, so English always comes first.)
    static let visionLanguages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        let latin: Set<String> = ["fr", "it", "de", "es", "pt", "nl", "sv", "da", "no", "nb", "nn", "fi", "pl", "cs", "ro", "tr", "id", "ms", "vi"]
        var out = ["en-US"]
        for pref in Locale.preferredLanguages {
            let code = String(pref.prefix { $0 != "-" && $0 != "_" })
            guard latin.contains(code), let match = supported.first(where: { $0.hasPrefix(code + "-") }), !out.contains(match) else { continue }
            out.append(match)
        }
        return out
    }()

    /// Reads the window's content area. `region` is in global screen points (top-left origin), nil for the whole window;
    /// `regionIsContent` says the region is the content itself (no layout filtering needed). `hebrew`: also run
    /// Tesseract when it is installed. Busy, or nothing changed on screen since the last read of `key` ⇒ nil.
    func recognize(pid: pid_t, key: String, region: CGRect?, regionIsContent: Bool, hebrew: Bool,
                   completion: @escaping (OCRReading?) -> Void) {
        lock.lock()
        if busy { lock.unlock(); completion(nil); return }
        busy = true
        lock.unlock()
        let finish: (OCRReading?) -> Void = { [weak self] reading in
            self?.lock.lock(); self?.busy = false; self?.lock.unlock()
            completion(reading)
        }
        guard Self.hasPermission else { finish(nil); return }
        guard let windowID = Self.frontWindowID(pid: pid) else { Self.note("no on-screen window"); finish(nil); return }
        let paths = self.paths
        Task.detached(priority: .utility) { [weak self] in
            do {
                let started = Date()
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    Self.note("window not shareable")
                    finish(nil)
                    return
                }
                let frame = window.frame
                // 2 pixels per point (Retina-native; text on 1× displays is enlarged for the OCR), at most ~12 MP
                let scale = min(2.0, (12_000_000 / max(frame.width * frame.height, 1)).squareRoot())
                let config = SCStreamConfiguration()
                config.width = max(1, Int(frame.width * scale))
                config.height = max(1, Int(frame.height * scale))
                config.showsCursor = false
                // the image must map onto the window frame exactly: no shadow margins, no clipping at screen edges
                config.ignoreShadowsSingleWindow = true
                config.ignoreGlobalClipSingleWindow = true
                config.shouldBeOpaque = true
                let shot = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: config)
                let (image, cropped) = Self.crop(shot, window: frame, region: region, scale: scale)
                if let print = Self.fingerprint(image), self?.unchanged(key, print) == true { finish(nil); return }
                finish(Self.read(image, hebrew: hebrew, regionIsContent: regionIsContent && cropped, paths: paths, started: started))
            } catch {
                Self.note("capture failed (\((error as NSError).domain) \((error as NSError).code))")
                finish(nil)
            }
        }
    }

    private static var notedAt: [String: Date] = [:]
    private static let noteLock = NSLock()

    /// Why a read did not happen — logged at most every 5 minutes per reason (no window content).
    static func note(_ reason: String) {
        noteLock.lock()
        defer { noteLock.unlock() }
        if let t = notedAt[reason], Date().timeIntervalSince(t) < 300 { return }
        notedAt[reason] = Date()
        Log.info("OCR skipped: \(reason)", "tracking")
    }

    /// The part of a window screenshot that shows `region` (both in global points); the whole shot if the region is
    /// unknown, tiny or outside the window.
    static func crop(_ shot: CGImage, window: CGRect, region: CGRect?, scale: CGFloat) -> (image: CGImage, cropped: Bool) {
        guard let region else { return (shot, false) }
        let local = region.intersection(window)
        guard !local.isNull, local.width >= 120, local.height >= 60 else { return (shot, false) }
        let px = CGRect(x: (local.minX - window.minX) * scale, y: (local.minY - window.minY) * scale,
                        width: local.width * scale, height: local.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        guard let image = shot.cropping(to: px) else { return (shot, false) }
        return (image, true)
    }

    /// Difference hash of a 33×32 grey thumbnail, folded to 64 bits: it changes when the text on screen changes (a
    /// scroll, a new page), not when a cursor blinks.
    public static func fingerprint(_ image: CGImage) -> UInt64? {
        let w = 33, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for y in 0..<h {
            var bits: UInt32 = 0
            for x in 0..<(w - 1) where pixels[y * w + x] > pixels[y * w + x + 1] { bits |= 1 << UInt32(x) }
            hash = (hash ^ UInt64(bits)) &* 0x0000_0100_0000_01B3
        }
        return hash ^ UInt64(image.width << 32 | image.height)
    }

    private func unchanged(_ key: String, _ print: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if lastPrint[key] == print { return true }
        if lastPrint.count > 500 { lastPrint.removeAll() }
        lastPrint[key] = print
        return false
    }

    /// Runs the engines on an image and returns its content lines.
    public static func read(_ image: CGImage, hebrew: Bool, regionIsContent: Bool, paths: AppPaths, started: Date = Date()) -> OCRReading {
        var vision = visionLines(image)
        var tesseract: [OCRWord] = []
        var usedTesseract = false
        let confidentLatin = vision.filter { $0.confidence >= OCRFusion.minVisionConfidence }.reduce(0) { $0 + $1.text.count }
        // Tesseract runs when Hebrew is expected, or when Vision could not read the text (likely a script it lacks)
        if (hebrew || confidentLatin < 40), TesseractOCR.isAvailable(paths), let png = pngData(image) {
            if let words = TesseractOCR.recognize(png: png, paths: paths) {
                tesseract = words
                usedTesseract = true
                // English words inside Hebrew lines that neither engine read: a closer look by Vision
                for box in OCRFusion.latinCandidates(tesseract: words, vision: vision) {
                    vision += visionLines(image, in: box)
                }
            }
        }
        var lines = OCRFusion.merge(tesseract: tesseract, vision: vision)
        if !regionIsContent { lines = OCRLayout.contentLines(lines, imageSize: CGSize(width: image.width, height: image.height)) }
        let text = lines.map(\.text).filter { $0.count >= 2 }
        return OCRReading(lines: text, usedTesseract: usedTesseract, seconds: Date().timeIntervalSince(started))
    }

    /// Vision's lines with the box of each word, in image pixels (top-left origin).
    static func visionLines(_ image: CGImage) -> [VisionLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // language correction only rewrites Latin words, and costs several times the recognition on non-Latin screens
        request.usesLanguageCorrection = false
        request.recognitionLanguages = visionLanguages
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        func pixels(_ b: CGRect) -> CGRect { CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h) }
        return (request.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            var words: [(text: String, box: CGRect)] = []
            c.string.enumerateSubstrings(in: c.string.startIndex..<c.string.endIndex, options: .byWords) { word, range, _, _ in
                if let word, let b = try? c.boundingBox(for: range)?.boundingBox { words.append((word, pixels(b))) }
            }
            return VisionLine(text: c.string, box: pixels(o.boundingBox), confidence: c.confidence, words: words)
        }
    }

    /// Vision on a small part of the image (padded, enlarged when the text is small), mapped back to image pixels.
    static func visionLines(_ image: CGImage, in box: CGRect) -> [VisionLine] {
        let pad = box.insetBy(dx: -0.4 * box.height, dy: -0.35 * box.height).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pad.isNull, pad.width >= 8, pad.height >= 8, var crop = image.cropping(to: pad) else { return [] }
        var zoom: CGFloat = 1
        if pad.height < 60, let big = scaled(crop, by: 2) { crop = big; zoom = 2 }
        return visionLines(crop).map { l in
            func back(_ r: CGRect) -> CGRect { CGRect(x: pad.minX + r.minX / zoom, y: pad.minY + r.minY / zoom, width: r.width / zoom, height: r.height / zoom) }
            return VisionLine(text: l.text, box: back(l.box), confidence: l.confidence, words: l.words.map { ($0.text, back($0.box)) })
        }
    }

    static func scaled(_ image: CGImage, by f: CGFloat) -> CGImage? {
        let w = Int(CGFloat(image.width) * f), h = Int(CGFloat(image.height) * f)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
