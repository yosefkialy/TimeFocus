import Foundation

/// Errors thrown while loading or running a `SentenceEncoder`.
public enum EncoderError: Error, CustomStringConvertible {
    /// A required model file is missing or unreadable (the associated value is the file name).
    case missingFile(String)
    /// `config.json` or `tokenizer.json` is malformed or inconsistent with the weights.
    case badConfig(String)
    /// `model.safetensors` is malformed or lacks an expected tensor.
    case badSafetensors(String)
    /// The model uses a feature this engine does not implement.
    case unsupported(String)

    public var description: String {
        switch self {
        case .missingFile(let s): return "Missing model file: \(s)"
        case .badConfig(let s): return "Invalid model configuration: \(s)"
        case .badSafetensors(let s): return "Invalid safetensors file: \(s)"
        case .unsupported(let s): return "Unsupported model: \(s)"
        }
    }
}

extension EncoderError: LocalizedError {
    public var errorDescription: String? { description }
}
