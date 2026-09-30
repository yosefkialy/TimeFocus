import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// On-device OCR of the focused window (ScreenCaptureKit + Vision). Optional — needs the Screen Recording
/// permission. The captured image is never stored; only recognised text is kept. Vision does not currently
/// support Hebrew, so Hebrew content is read through the Accessibility API instead.
final class OCRService {
    private var busy = false
    private let lock = NSLock()

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

    func recognize(pid: pid_t, languages: [String], completion: @escaping (String?) -> Void) {
        lock.lock()
        if busy { lock.unlock(); completion(nil); return }
        busy = true
        lock.unlock()
        let finish: (String?) -> Void = { [weak self] text in
            self?.lock.lock(); self?.busy = false; self?.lock.unlock()
            completion(text)
        }
        guard Self.hasPermission, let windowID = Self.frontWindowID(pid: pid) else { finish(nil); return }
        Task.detached(priority: .utility) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { finish(nil); return }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let scale = min(2.0, 1600.0 / max(window.frame.width, 1))
                config.width = Int(window.frame.width * scale)
                config.height = Int(window.frame.height * scale)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                finish(Self.ocr(image, languages: languages))
            } catch {
                Log.debug("OCR capture failed: \(error)", "tracking")
                finish(nil)
            }
        }
    }

    static func ocr(_ image: CGImage, languages: [String]) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.012
        if let supported = try? request.supportedRecognitionLanguages() {
            let wanted = languages.filter { supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence > 0.4 }
            .map(\.string)
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(3000))
    }
}
