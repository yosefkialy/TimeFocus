import Foundation

/// Hebrew OCR with the Tesseract command-line tool (installed with Homebrew or MacPorts) and its Hebrew model, which the
/// user downloads from the Learning screen. Apple's Vision has no Hebrew; Tesseract's `heb` model reads on-screen Hebrew
/// almost perfectly at Retina resolution. Each read is a short-lived, low-priority child process: nothing stays in
/// memory between reads, and a hung or crashing OCR can never take TimeFocus down. The image goes through a pipe and
/// is never written to disk.
public enum TesseractOCR {
    public static let candidatePaths = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract", "/opt/local/bin/tesseract"]
    /// The model this app downloads (tessdata_best: LSTM, ~3.7 MB). It knows Hebrew letters, digits and punctuation —
    /// no Latin letters; Vision reads those.
    public static let language = "heb"

    public static func binary() -> URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func modelDirectory(_ paths: AppPaths) -> URL { paths.models.appendingPathComponent("tesseract", isDirectory: true) }

    public static func isModelInstalled(_ paths: AppPaths) -> Bool {
        let url = modelDirectory(paths).appendingPathComponent("\(language).traineddata")
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0) > 0
    }

    /// Both the program and the Hebrew model are present.
    public static func isAvailable(_ paths: AppPaths) -> Bool { binary() != nil && isModelInstalled(paths) }

    /// Words of a PNG screenshot taken at `dpi` (144 for 2× pixels). Nil if Tesseract failed or ran past `timeout`.
    public static func recognize(png: Data, dpi: Int = 144, paths: AppPaths, timeout: TimeInterval = 20) -> [OCRWord]? {
        guard let bin = binary() else { return nil }
        let p = Process()
        p.executableURL = bin
        // page segmentation 3 (automatic layout): sidebars, headers and paragraphs come out as separate blocks
        p.arguments = ["stdin", "stdout", "--tessdata-dir", modelDirectory(paths).path, "-l", language, "--psm", "3",
                       "--dpi", String(dpi), "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=0"]
        var env = ProcessInfo.processInfo.environment
        env["OMP_THREAD_LIMIT"] = "1"
        env.removeValue(forKey: "TESSDATA_PREFIX")
        p.environment = env
        p.qualityOfService = .utility
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.debug("tesseract failed to start: \(error)", "tracking")
            return nil
        }
        let writer = input.fileHandleForWriting
        // a write to a pipe whose reader died must fail with EPIPE, not kill TimeFocus with SIGPIPE
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: png) // fails harmlessly if the process died
            try? writer.close()
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            Log.debug("tesseract exited with \(p.terminationStatus) (\(p.terminationReason == .uncaughtSignal ? "signal" : "exit"))", "tracking")
            return nil
        }
        return OCRFusion.parseTesseractTSV(String(decoding: data, as: UTF8.self))
    }
}
