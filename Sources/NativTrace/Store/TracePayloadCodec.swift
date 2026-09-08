import Compression
import Foundation

/// How a payload blob is stored.
///
/// Compression is a storage detail, never a format detail: an exported trace is
/// always plain JSON. Keeping the two separate is what lets the on-disk codec
/// change later without invalidating traces anyone has already exported.
public enum TracePayloadCodec {
    public static let plain = "json"
    public static let deflated = "json+deflate"

    /// Below this, framing overhead outweighs any saving.
    private static let compressionThreshold = 512

    public struct Encoded {
        public let data: Data
        public let encoding: String
        /// Uncompressed byte count, required to size the decode buffer.
        public let byteCount: Int
    }

    public static func encode(_ payload: TraceJSON) throws -> Encoded {
        let raw = try payload.canonicalData()
        guard raw.count >= compressionThreshold,
              let compressed = deflate(raw),
              compressed.count < raw.count
        else {
            return Encoded(data: raw, encoding: plain, byteCount: raw.count)
        }
        return Encoded(data: compressed, encoding: deflated, byteCount: raw.count)
    }

    public static func decode(data: Data, encoding: String, byteCount: Int) throws -> TraceJSON {
        switch encoding {
        case plain:
            return try TraceJSON.decode(data)
        case deflated:
            guard let raw = inflate(data, expectedCount: byteCount) else {
                throw TraceStoreError.corruptPayload("could not inflate payload")
            }
            return try TraceJSON.decode(raw)
        default:
            throw TraceStoreError.unsupportedPayloadEncoding(encoding)
        }
    }

    private static func deflate(_ input: Data) -> Data? {
        transform(input, capacity: input.count, operation: COMPRESSION_STREAM_ENCODE)
    }

    private static func inflate(_ input: Data, expectedCount: Int) -> Data? {
        transform(input, capacity: max(expectedCount, 1), operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(
        _ input: Data,
        capacity: Int,
        operation: compression_stream_operation
    ) -> Data? {
        guard !input.isEmpty else { return Data() }
        let apply = operation == COMPRESSION_STREAM_ENCODE
            ? compression_encode_buffer
            : compression_decode_buffer

        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return apply(destinationBase, capacity, sourceBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output
    }
}
