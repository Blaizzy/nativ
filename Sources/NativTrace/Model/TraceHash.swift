import CryptoKit
import Foundation

/// Content hashing used to reference message bodies instead of repeating them.
///
/// Truncated to 128 bits: this guards against a reader silently resolving a
/// reference to the wrong body after an edit or a branch, not against an
/// adversary, and halving the string keeps traces readable when exported.
public enum TraceHash {
    public static func content(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
