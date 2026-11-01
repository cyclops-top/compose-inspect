import Foundation

/// A model-independent heuristic, not a tokenizer or billing count.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        // ASCII averages four characters per token; non-ASCII averages two
        // UTF-8 bytes per token (about 1.5 tokens per common Chinese character).
        let quarterTokens = text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.isASCII ? 1 : scalar.utf8.count * 2)
        }
        return (quarterTokens + 3) / 4
    }
}
