import Foundation

/// Files a model directory must contain for `SentenceEncoder(directory:)`.
public enum SentenceEncoderFiles {
    public static let required = ["config.json", "model.safetensors", "tokenizer.json"]
}

/// On-device multilingual sentence embeddings (e.g. `intfloat/multilingual-e5-small`,
/// `paraphrase-multilingual-MiniLM-L12-v2`): SentencePiece-Unigram tokenizer + BERT encoder +
/// attention-mask mean pooling + L2 normalisation, in pure Swift on Accelerate.
///
/// All state is immutable after `init` (scratch memory is allocated per call), so an instance may be
/// shared between threads; callers are still expected to serialise work to bound peak memory.
public final class SentenceEncoder: @unchecked Sendable {
    /// Name of the model directory, e.g. "multilingual-e5-small".
    public let modelID: String
    /// Embedding size (hidden size of the encoder), 384 for e5-small.
    public let dimension: Int
    /// `max_position_embeddings` from config.json (512 for e5-small).
    public let maxPositions: Int

    private let tokenizer: UnigramTokenizer
    private let model: BertModel

    /// Upper bound on tokens per forward pass; larger batches are processed in chunks so scratch
    /// memory stays around 50 MB regardless of what the caller passes.
    private static let maxTokensPerForward = 4096

    /// Loads `config.json`, `tokenizer.json` and `model.safetensors` from `directory`.
    public init(directory: URL) throws {
        for name in SentenceEncoderFiles.required {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.isReadableFile(atPath: path) else { throw EncoderError.missingFile(name) }
        }
        let config = try BertConfig(contentsOf: directory.appendingPathComponent("config.json"))
        let tokenizer = try UnigramTokenizer(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        let weights = try SafetensorsFile(url: directory.appendingPathComponent("model.safetensors"))
        let model = try BertModel(config: config, weights: weights)
        guard tokenizer.vocabularySize <= model.embeddingRows else {
            throw EncoderError.badConfig("tokenizer has \(tokenizer.vocabularySize) tokens but the embedding matrix only \(model.embeddingRows) rows")
        }
        self.modelID = directory.standardizedFileURL.lastPathComponent
        self.dimension = config.hiddenSize
        self.maxPositions = config.maxPositions
        self.tokenizer = tokenizer
        self.model = model
    }

    /// L2-normalised mean-pooled embeddings (attention-mask-weighted mean over the last hidden state),
    /// one per input, order preserved. Each text is truncated to `maxTokens` tokens INCLUDING special
    /// tokens (and to the model's position limit). The caller adds any model-specific prefix itself
    /// (e.g. "query: " for e5).
    public func encode(_ texts: [String], maxTokens: Int = 128) throws -> [[Float]] {
        if texts.isEmpty { return [] }
        let limit = max(tokenizer.specialTokenCount, 1, min(maxTokens, model.config.maxSequenceLength))
        let sequences = texts.map { tokenizer.encode($0, maxTokens: limit) }

        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        var chunk: [[Int32]] = []
        var chunkTokens = 0
        for ids in sequences {
            if !chunk.isEmpty && chunkTokens + ids.count > Self.maxTokensPerForward {
                result += model.embed(chunk)
                chunk.removeAll(keepingCapacity: true)
                chunkTokens = 0
            }
            chunk.append(ids)
            chunkTokens += ids.count
        }
        if !chunk.isEmpty { result += model.embed(chunk) }
        return result
    }

    /// Token ids including special tokens (`<s> … </s>`), truncated to `maxTokens`.
    public func tokenize(_ text: String, maxTokens: Int = 512) -> [Int32] {
        tokenizer.encode(text, maxTokens: maxTokens)
    }

    /// Approximate bytes of model data resident in memory: owned transformer weights, tokenizer tables,
    /// and the pages of the memory-mapped word-embedding matrix touched so far.
    public var approximateMemoryBytes: Int {
        model.ownedWeightBytes + tokenizer.approximateMemoryBytes + model.residentEmbeddingBytes
    }
}
