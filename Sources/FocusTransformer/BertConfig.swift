import Foundation

/// Hyper-parameters of a BERT-family encoder, read from HuggingFace `config.json`.
struct BertConfig {
    enum Activation {
        case geluErf    // "gelu": 0.5·x·(1+erf(x/√2)) — BERT / e5 / MiniLM
        case geluTanh   // "gelu_new", "gelu_pytorch_tanh", "gelu_fast"
        case relu
    }

    var modelType: String
    var hiddenSize: Int
    var numLayers: Int
    var numHeads: Int
    var intermediateSize: Int
    var maxPositions: Int
    var vocabSize: Int
    var typeVocabSize: Int
    var layerNormEps: Float
    var activation: Activation
    var padTokenId: Int
    /// First position id used for a sequence. BERT counts positions from 0; RoBERTa-family models
    /// (XLM-R, CamemBERT) start at `padding_idx + 1` (they reserve rows for padding).
    var positionOffset: Int

    var headDim: Int { hiddenSize / numHeads }
    /// Longest sequence (including special tokens) the position table supports.
    var maxSequenceLength: Int { maxPositions - positionOffset }

    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw EncoderError.missingFile(url.lastPathComponent) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EncoderError.badConfig("config.json is not a JSON object")
        }
        try self.init(json: json)
    }

    init(json: [String: Any]) throws {
        func int(_ key: String, default value: Int? = nil) throws -> Int {
            if let n = json[key] as? NSNumber { return n.intValue }
            if let value { return value }
            throw EncoderError.badConfig("config.json: missing '\(key)'")
        }
        let architectures = json["architectures"] as? [String] ?? []
        modelType = (json["model_type"] as? String ?? "").lowercased()
        switch modelType {
        case "bert":
            positionOffset = 0
        case "xlm-roberta", "roberta", "camembert":
            positionOffset = try int("pad_token_id", default: 1) + 1
        case "":
            guard architectures.contains(where: { $0.hasPrefix("Bert") }) else {
                throw EncoderError.unsupported("config.json has no model_type and is not a BERT architecture")
            }
            positionOffset = 0
        default:
            throw EncoderError.unsupported("model_type '\(modelType)' (only BERT / RoBERTa-family encoders are supported)")
        }
        hiddenSize = try int("hidden_size")
        numLayers = try int("num_hidden_layers")
        numHeads = try int("num_attention_heads")
        intermediateSize = try int("intermediate_size")
        maxPositions = try int("max_position_embeddings")
        vocabSize = try int("vocab_size")
        typeVocabSize = try int("type_vocab_size", default: 2)
        padTokenId = try int("pad_token_id", default: 0)
        layerNormEps = Float((json["layer_norm_eps"] as? NSNumber)?.doubleValue ?? 1e-12)

        let act = (json["hidden_act"] as? String ?? "gelu").lowercased()
        switch act {
        case "gelu": activation = .geluErf
        case "gelu_new", "gelu_pytorch_tanh", "gelu_fast": activation = .geluTanh
        case "relu": activation = .relu
        default: throw EncoderError.unsupported("hidden_act '\(act)'")
        }
        let positionType = json["position_embedding_type"] as? String ?? "absolute"
        guard positionType == "absolute" else {
            throw EncoderError.unsupported("position_embedding_type '\(positionType)'")
        }
        guard hiddenSize > 0, numLayers > 0, numHeads > 0, hiddenSize % numHeads == 0,
              intermediateSize > 0, vocabSize > 0, typeVocabSize > 0, maxPositions > positionOffset + 2 else {
            throw EncoderError.badConfig("config.json: inconsistent dimensions")
        }
    }
}
