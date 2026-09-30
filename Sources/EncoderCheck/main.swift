// EncoderCheck [modelDir]
//
// Loads the on-device sentence encoder and verifies it against values recorded from the reference
// implementation (HuggingFace tokenizers + PyTorch), then reports speed and memory.
// Exit status: 0 when every correctness check passes, 1 otherwise (timings only warn).

import Foundation
import FocusTransformer

// MARK: - Helpers

var failures = 0
var passes = 0
var warnings = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    print("  [\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : "  (\(detail))")")
    if ok { passes += 1 } else { failures += 1 }
}

func warnUnless(_ ok: Bool, _ label: String) {
    print("  [\(ok ? " OK " : "WARN")] \(label)")
    if !ok { warnings += 1 }
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .nan }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
        dot += Double(a[i]) * Double(b[i])
        na += Double(a[i]) * Double(a[i])
        nb += Double(b[i]) * Double(b[i])
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func median(_ values: [Double]) -> Double {
    let s = values.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func peakRSSBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)   // bytes on macOS
}

func footprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }

func firstDifference(_ a: [Int32], _ b: [Int32]) -> String {
    let i = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
    return "first difference at index \(i); got \(a.count) ids \(Array(a.prefix(24))), expected \(b.count) ids \(Array(b.prefix(24)))"
}

// MARK: - Arguments

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("-h") || arguments.contains("--help") {
    print("usage: EncoderCheck [modelDir]\n  default modelDir: ~/Library/Application Support/TimeFocus/Models/multilingual-e5-small")
    exit(0)
}
let modelDirectory: URL = {
    if let path = arguments.first { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("TimeFocus/Models/multilingual-e5-small")
}()

print("EncoderCheck — on-device sentence encoder self-test")
print("model directory: \(modelDirectory.path)")

// MARK: - 1. Load

print("\n1. Load")
let encoder: SentenceEncoder
let loadStart = seconds()
do {
    encoder = try SentenceEncoder(directory: modelDirectory)
} catch {
    print("  [FAIL] cannot load model: \(error)")
    print("\nRESULT: FAIL")
    exit(1)
}
let loadTime = seconds() - loadStart
print("  loaded '\(encoder.modelID)' in \(ms(loadTime)); footprint \(mb(footprintBytes())), approx model memory \(mb(encoder.approximateMemoryBytes))")
check(encoder.dimension == 384, "dimension is 384", "\(encoder.dimension)")
check(encoder.maxPositions == 512, "maxPositions is 512", "\(encoder.maxPositions)")

// MARK: - 2. Tokenizer

print("\n2. Tokenizer (exact ids vs HuggingFace tokenizers)")
for c in Reference.tokenCases {
    let ids = encoder.tokenize(c.text, maxTokens: 512)
    let label = c.text.isEmpty ? "\"\" (empty string)" : c.text.debugDescription
    check(ids == c.ids, "ids of \(label.count > 60 ? String(label.prefix(57)) + "…\"" : label)",
          ids == c.ids ? "\(ids.count) ids" : firstDifference(ids, c.ids))
}
let fullCount = encoder.tokenize(Reference.truncationText, maxTokens: 100_000).count
check(fullCount == Reference.truncationFullCount, "untruncated paragraph length", "\(fullCount) ids, expected \(Reference.truncationFullCount)")
let truncated = encoder.tokenize(Reference.truncationText, maxTokens: 128)
check(truncated == Reference.truncationIds128, "paragraph truncated to 128 ids (<s> … </s>)",
      truncated == Reference.truncationIds128 ? "\(truncated.count) ids" : firstDifference(truncated, Reference.truncationIds128))
check(encoder.tokenize("query: hello", maxTokens: 2) == [0, 2], "maxTokens 2 keeps only <s> </s>")

// MARK: - 3. Embeddings

print("\n3. Embeddings (vs PyTorch float32 reference)")
var embeddingsOK = true
do {
    let texts = Reference.embeddingCases.map { $0.text }
    let batch = try encoder.encode(texts, maxTokens: 128)
    check(batch.count == texts.count && batch.allSatisfy { $0.count == 384 }, "batch returns \(texts.count) vectors of 384 dims")
    for (i, c) in Reference.embeddingCases.enumerated() where i < batch.count {
        let v = batch[i]
        let maxDiff8 = zip(v.prefix(8), c.vector.prefix(8)).map { abs($0 - $1) }.max() ?? .infinity
        let cos = cosine(v, c.vector)
        let norm = v.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        let short = c.text.count > 40 ? String(c.text.prefix(40)) + "…" : c.text
        check(maxDiff8 <= 1e-3, "first 8 dims of \"\(short)\"", String(format: "max |diff| %.2e", maxDiff8))
        check(cos >= 0.9999, "cosine vs reference for \"\(short)\"", String(format: "%.7f", cos))
        check(abs(norm - 1) < 1e-4, "unit norm", String(format: "%.6f", norm))
        embeddingsOK = embeddingsOK && maxDiff8 <= 1e-3 && cos >= 0.9999
        let alone = try encoder.encode([c.text], maxTokens: 128)[0]
        check(cosine(alone, v) >= 0.99999, "same vector when encoded alone vs in a batch", String(format: "%.7f", cosine(alone, v)))
    }
    check(try encoder.encode([]).isEmpty, "empty input gives empty output")
} catch {
    check(false, "encode threw: \(error)")
}

// MARK: - 4. Semantic sanity

print("\n4. Semantic sanity")
do {
    let v = try encoder.encode(["query: linear algebra eigenvalues", "query: אלגברה לינארית ערכים עצמיים",
                                "query: funny cat videos compilation", "query: main.swift — time_focus",
                                "query: Xcode — Build Succeeded | TimeFocus.xcodeproj"])
    let enHe = cosine(v[0], v[1]), enCat = cosine(v[0], v[2])
    check(enHe > enCat, "cos(EN linear algebra, HE linear algebra) > cos(EN linear algebra, cat videos)",
          String(format: "%.4f > %.4f", enHe, enCat))
    let code = cosine(v[3], v[4]), codeCat = cosine(v[3], v[2])
    check(code > codeCat, "cos(main.swift window, Xcode window) > cos(main.swift window, cat videos)",
          String(format: "%.4f > %.4f", code, codeCat))
} catch {
    check(false, "encode threw: \(error)")
}

// MARK: - 5. Performance (informational)

print("\n5. Performance")
do {
    let single = "query: main.swift — time_focus — Xcode build succeeded"
    let singleTokens = encoder.tokenize(single).count
    for _ in 0..<5 { _ = try encoder.encode([single]) }
    var times: [Double] = []
    for _ in 0..<30 {
        let t = seconds()
        _ = try encoder.encode([single])
        times.append(seconds() - t)
    }
    let singleMedian = median(times)
    warnUnless(singleMedian < 0.020, "single text (\(singleTokens) tokens): median \(ms(singleMedian)), min \(ms(times.min()!)) — target < 20 ms")

    let batch = (0..<16).map { "query: document \($0). " + Reference.truncationText }
    let batchTokens = batch.map { encoder.tokenize($0, maxTokens: 128).count }
    for _ in 0..<2 { _ = try encoder.encode(batch, maxTokens: 128) }
    times = []
    for _ in 0..<5 {
        let t = seconds()
        _ = try encoder.encode(batch, maxTokens: 128)
        times.append(seconds() - t)
    }
    let batchMedian = median(times)
    let totalTokens = batchTokens.reduce(0, +)
    warnUnless(batchMedian < 0.6, "batch of 16 × \(batchTokens.max()!) tokens: median \(ms(batchMedian)) (\(Int(Double(totalTokens) / batchMedian)) tokens/s) — target < 600 ms")
} catch {
    check(false, "encode threw: \(error)")
}

// MARK: - 6. Memory

print("\n6. Memory")
print("  peak RSS \(mb(peakRSSBytes())), current footprint \(mb(footprintBytes())), approximateMemoryBytes \(mb(encoder.approximateMemoryBytes))")

// MARK: - Summary

print("")
if failures == 0 {
    print("RESULT: PASS — \(passes) checks passed\(warnings > 0 ? ", \(warnings) performance warning(s)" : "")")
    exit(0)
} else {
    print("RESULT: FAIL — \(failures) of \(passes + failures) checks failed")
    exit(1)
}
