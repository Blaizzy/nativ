import CryptoKit
import Foundation

public enum TraceHash {
    public static func content(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
