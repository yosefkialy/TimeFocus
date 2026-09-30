import Accelerate
import Foundation

/// BERT encoder (post-LayerNorm, absolute positions) with mean pooling, in Float32 on Accelerate.
///
/// A batch is run *packed*: all sequences are concatenated into one `[T, hidden]` matrix (T = total
/// tokens) for the dense layers, and attention is computed per sequence and head on strided views of
/// the fused Q/K/V matrix. This is numerically equivalent to padding every sequence to the longest one
/// and masking padded keys with a large negative number, but spends no FLOPs on padding.
final class BertModel {
    let config: BertConfig
    /// Bytes of weights copied into owned buffers (everything except the word-embedding matrix).
    let ownedWeightBytes: Int

    private let file: SafetensorsFile           // keeps the mapping alive for embedding lookups
    private let wordEmbeddings: SafetensorsFile.Tensor
    private let positionEmbeddings: FloatBuffer // [maxPositions, H]
    private let tokenTypeEmbedding: FloatBuffer // row 0 of token_type_embeddings (single-segment input)
    private let embeddingNormWeight: FloatBuffer
    private let embeddingNormBias: FloatBuffer
    private let layers: [Layer]
    private let residency: PageResidency

    var embeddingRows: Int { wordEmbeddings.shape[0] }
    /// Estimated resident bytes of the memory-mapped word-embedding matrix (pages touched so far).
    var residentEmbeddingBytes: Int { residency.residentBytes }

    private struct Layer {
        let qkvWeight: FloatBuffer          // [3H, H]: query, key, value rows stacked (PyTorch [out, in] layout)
        let qkvBias: FloatBuffer            // [3H]
        let attentionOutWeight: FloatBuffer // [H, H]
        let attentionOutBias: FloatBuffer
        let attentionNormWeight: FloatBuffer
        let attentionNormBias: FloatBuffer
        let intermediateWeight: FloatBuffer // [I, H]
        let intermediateBias: FloatBuffer
        let outputWeight: FloatBuffer       // [H, I]
        let outputBias: FloatBuffer
        let outputNormWeight: FloatBuffer
        let outputNormBias: FloatBuffer
    }

    init(config: BertConfig, weights: SafetensorsFile) throws {
        self.config = config
        self.file = weights
        let H = config.hiddenSize, I = config.intermediateSize

        // Checkpoints differ only by a name prefix: "", "bert.", "model.", "0.auto_model." …
        let anchor = "embeddings.word_embeddings.weight"
        guard let wordKey = weights.tensors.keys.filter({ $0.hasSuffix(anchor) }).min(by: { $0.count < $1.count }) else {
            throw EncoderError.badSafetensors("no '*\(anchor)' tensor found")
        }
        let prefix = String(wordKey.dropLast(anchor.count))

        func find(_ name: String) throws -> SafetensorsFile.Tensor {
            var names = [prefix + name]
            if name.hasSuffix(".LayerNorm.weight") { names.append(prefix + name.dropLast(6) + "gamma") }
            if name.hasSuffix(".LayerNorm.bias") { names.append(prefix + name.dropLast(4) + "beta") }
            for n in names { if let t = weights.tensor(n) { return t } }
            throw EncoderError.badSafetensors("missing tensor '\(prefix + name)'")
        }
        var owned = 0
        func load(_ name: String, _ shape: [Int]) throws -> FloatBuffer {
            let t = try find(name)
            guard t.shape == shape else {
                throw EncoderError.badSafetensors("tensor '\(t.name)' has shape \(t.shape), expected \(shape)")
            }
            let buffer = try weights.readFloats(t)
            owned += buffer.byteCount
            return buffer
        }

        let word = try find("embeddings.word_embeddings.weight")
        guard word.shape.count == 2, word.shape[1] == H, word.shape[0] > 0, word.dtype.isConvertibleToFloat else {
            throw EncoderError.badSafetensors("word embeddings have shape \(word.shape) / dtype \(word.dtype.rawValue)")
        }
        wordEmbeddings = word
        positionEmbeddings = try load("embeddings.position_embeddings.weight", [config.maxPositions, H])
        let tokenTypes = try load("embeddings.token_type_embeddings.weight", [config.typeVocabSize, H])
        tokenTypeEmbedding = FloatBuffer(count: H)
        tokenTypeEmbedding.pointer.initialize(from: tokenTypes.pointer, count: H)
        owned += H * 4 - tokenTypes.byteCount
        embeddingNormWeight = try load("embeddings.LayerNorm.weight", [H])
        embeddingNormBias = try load("embeddings.LayerNorm.bias", [H])

        var layers: [Layer] = []
        for l in 0..<config.numLayers {
            let p = "encoder.layer.\(l)."
            // Fuse the three projections so Q, K and V come out of a single GEMM.
            let qkvWeight = FloatBuffer(count: 3 * H * H)
            let qkvBias = FloatBuffer(count: 3 * H)
            for (i, part) in ["query", "key", "value"].enumerated() {
                let w = try load(p + "attention.self.\(part).weight", [H, H])
                let b = try load(p + "attention.self.\(part).bias", [H])
                (qkvWeight.pointer + i * H * H).initialize(from: w.pointer, count: H * H)
                (qkvBias.pointer + i * H).initialize(from: b.pointer, count: H)
            }
            layers.append(Layer(
                qkvWeight: qkvWeight, qkvBias: qkvBias,
                attentionOutWeight: try load(p + "attention.output.dense.weight", [H, H]),
                attentionOutBias: try load(p + "attention.output.dense.bias", [H]),
                attentionNormWeight: try load(p + "attention.output.LayerNorm.weight", [H]),
                attentionNormBias: try load(p + "attention.output.LayerNorm.bias", [H]),
                intermediateWeight: try load(p + "intermediate.dense.weight", [I, H]),
                intermediateBias: try load(p + "intermediate.dense.bias", [I]),
                outputWeight: try load(p + "output.dense.weight", [H, I]),
                outputBias: try load(p + "output.dense.bias", [H]),
                outputNormWeight: try load(p + "output.LayerNorm.weight", [H]),
                outputNormBias: try load(p + "output.LayerNorm.bias", [H])))
        }
        self.layers = layers
        ownedWeightBytes = owned
        residency = PageResidency(byteOffset: word.fileOffset, rowBytes: H * word.dtype.byteSize,
                                  totalBytes: word.byteCount)
    }

    /// Mean-pooled (over all tokens of each sequence), L2-normalised last hidden states.
    /// Each sequence must be non-empty and at most `config.maxSequenceLength` long.
    func embed(_ batch: [[Int32]]) -> [[Float]] {
        let H = config.hiddenSize, I = config.intermediateSize
        let heads = config.numHeads, dh = config.headDim, eps = config.layerNormEps
        let lengths = batch.map { min($0.count, config.maxSequenceLength) }
        var offsets: [Int] = []
        var total = 0
        for l in lengths { offsets.append(total); total += l }
        guard total > 0, let maxLength = lengths.max() else {
            return batch.map { _ in [Float](repeating: 0, count: H) }
        }
        residency.touch(rows: batch.joined())

        let hidden = FloatBuffer(count: total * H)       // layer input / output
        let attended = FloatBuffer(count: total * H)     // after the attention block
        let context = FloatBuffer(count: total * H)      // concatenated head outputs
        let qkv = FloatBuffer(count: total * 3 * H)
        let intermediate = FloatBuffer(count: total * I)
        let x = hidden.pointer, a = attended.pointer

        // Attention work items are (sequence, head) pairs; spread them over cores only when the batch
        // is big enough to amortise the dispatch (a single short text stays on the calling thread).
        let attentionTasks = batch.indices.filter { lengths[$0] > 0 }.flatMap { s in (0..<heads).map { (s, $0) } }
        let attentionCost = lengths.reduce(0) { $0 + $1 * $1 } * heads
        let attentionWorkers = attentionCost >= 150_000 ? min(8, attentionTasks.count) : 1
        let scoreBuffers = (0..<attentionWorkers).map { _ in FloatBuffer(count: maxLength * maxLength) }

        // Embeddings: word + position + token type 0, then LayerNorm.
        let rows = embeddingRows
        for (s, ids) in batch.enumerated() {
            for p in 0..<lengths[s] {
                let row = x + (offsets[s] + p) * H
                let id = Int(ids[p])
                if id >= 0 && id < rows {
                    file.gather(wordEmbeddings, start: id * H, count: H, into: row)
                } else {
                    row.update(repeating: 0, count: H)   // cannot happen with a matching tokenizer
                }
                vDSP_vadd(row, 1, positionEmbeddings.pointer + (p + config.positionOffset) * H, 1, row, 1, vDSP_Length(H))
                vDSP_vadd(row, 1, tokenTypeEmbedding.pointer, 1, row, 1, vDSP_Length(H))
            }
        }
        Kernels.layerNorm(x, rows: total, n: H, gamma: embeddingNormWeight.pointer, beta: embeddingNormBias.pointer, eps: eps)

        let scale = 1 / Float(dh).squareRoot()
        for layer in layers {
            // Q|K|V = x·Wqkvᵀ + b  → [T, 3H]
            Kernels.fillRows(qkv.pointer, rows: total, bias: layer.qkvBias.pointer, n: 3 * H)
            Kernels.gemm(transB: true, m: total, n: 3 * H, k: H, a: x, lda: H,
                         b: layer.qkvWeight.pointer, ldb: H, beta: 1, c: qkv.pointer, ldc: 3 * H)
            // Scaled dot-product attention per sequence and head: softmax(q·kᵀ/√d)·v on strided views
            // of the fused Q|K|V matrix. Only real tokens are present, so no mask is needed.
            let qkvBase = qkv.pointer, contextBase = context.pointer
            let attend = { (worker: Int) in
                let scores = scoreBuffers[worker].pointer
                for t in stride(from: worker, to: attentionTasks.count, by: attentionWorkers) {
                    let (s, h) = attentionTasks[t]
                    let L = lengths[s]
                    let q = qkvBase + offsets[s] * 3 * H + h * dh, k = q + H, v = q + 2 * H
                    Kernels.gemm(transB: true, m: L, n: L, k: dh, alpha: scale, a: q, lda: 3 * H,
                                 b: k, ldb: 3 * H, beta: 0, c: scores, ldc: L)
                    Kernels.softmaxRows(scores, rows: L, n: L)
                    Kernels.gemm(transB: false, m: L, n: dh, k: L, a: scores, lda: L,
                                 b: v, ldb: 3 * H, beta: 0, c: contextBase + offsets[s] * H + h * dh, ldc: H)
                }
            }
            if attentionWorkers > 1 {
                DispatchQueue.concurrentPerform(iterations: attentionWorkers, execute: attend)
            } else {
                attend(0)
            }
            // a = LayerNorm(x + context·Woᵀ + bo)
            Kernels.addBiasRows(x, bias: layer.attentionOutBias.pointer, into: a, rows: total, n: H)
            Kernels.gemm(transB: true, m: total, n: H, k: H, a: context.pointer, lda: H,
                         b: layer.attentionOutWeight.pointer, ldb: H, beta: 1, c: a, ldc: H)
            Kernels.layerNorm(a, rows: total, n: H, gamma: layer.attentionNormWeight.pointer,
                              beta: layer.attentionNormBias.pointer, eps: eps)
            // x = LayerNorm(a + act(a·Wiᵀ + bi)·Wo2ᵀ + bo2)
            Kernels.fillRows(intermediate.pointer, rows: total, bias: layer.intermediateBias.pointer, n: I)
            Kernels.gemm(transB: true, m: total, n: I, k: H, a: a, lda: H,
                         b: layer.intermediateWeight.pointer, ldb: H, beta: 1, c: intermediate.pointer, ldc: I)
            switch config.activation {
            case .geluErf: Kernels.geluErf(intermediate.pointer, count: total * I)
            case .geluTanh: Kernels.geluTanh(intermediate.pointer, count: total * I)
            case .relu: Kernels.relu(intermediate.pointer, count: total * I)
            }
            Kernels.addBiasRows(a, bias: layer.outputBias.pointer, into: x, rows: total, n: H)
            Kernels.gemm(transB: true, m: total, n: H, k: I, a: intermediate.pointer, lda: I,
                         b: layer.outputWeight.pointer, ldb: I, beta: 1, c: x, ldc: H)
            Kernels.layerNorm(x, rows: total, n: H, gamma: layer.outputNormWeight.pointer,
                              beta: layer.outputNormBias.pointer, eps: eps)
        }

        // Mean pooling over every token of the sequence (the attention mask is all ones), then L2 norm.
        var result: [[Float]] = []
        result.reserveCapacity(batch.count)
        for s in 0..<batch.count {
            var v = [Float](repeating: 0, count: H)
            let L = lengths[s]
            if L > 0 {
                v.withUnsafeMutableBufferPointer { out in
                    let o = out.baseAddress!
                    for p in 0..<L { vDSP_vadd(o, 1, x + (offsets[s] + p) * H, 1, o, 1, vDSP_Length(H)) }
                    var count = Float(L)
                    vDSP_vsdiv(o, 1, &count, o, 1, vDSP_Length(H))
                    var sumSquares: Float = 0
                    vDSP_svesq(o, 1, &sumSquares, vDSP_Length(H))
                    var norm = max(sumSquares.squareRoot(), 1e-12)
                    vDSP_vsdiv(o, 1, &norm, o, 1, vDSP_Length(H))
                }
            }
            result.append(v)
        }
        return result
    }
}

/// Tracks which pages of the memory-mapped embedding matrix have been read, to estimate how much of
/// it is resident (for display). Thread-safe.
private final class PageResidency {
    private let byteOffset: Int
    private let rowBytes: Int
    private let pageSize: Int
    private var bits: [UInt64]
    private var touchedPages = 0
    private let lock = NSLock()

    init(byteOffset: Int, rowBytes: Int, totalBytes: Int) {
        self.byteOffset = byteOffset
        self.rowBytes = rowBytes
        pageSize = max(Int(getpagesize()), 4096)
        let pages = (byteOffset + totalBytes) / pageSize + 2
        bits = [UInt64](repeating: 0, count: pages / 64 + 1)
    }

    var residentBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return touchedPages * pageSize
    }

    func touch<S: Sequence>(rows: S) where S.Element == Int32 {
        lock.lock(); defer { lock.unlock() }
        for row in rows where row >= 0 {
            let start = byteOffset + Int(row) * rowBytes
            var page = start / pageSize
            let last = (start + rowBytes - 1) / pageSize
            while page <= last && page / 64 < bits.count {
                let mask: UInt64 = 1 << UInt64(page % 64)
                if bits[page / 64] & mask == 0 { bits[page / 64] |= mask; touchedPages += 1 }
                page += 1
            }
        }
    }
}
