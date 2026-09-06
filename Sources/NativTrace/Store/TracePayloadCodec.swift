import Compression
import Foundation

/// How a payload blob is stored.
///
/// Compression is a storage detail, never a format detail: an exported trace is
/// always plain JSON. Keeping the two separate is what lets the on-disk codec
/// change later without invalidating traces anyone has already exported.
enum TracePayloadCodec {
    static let plain = "json"
    static let deflated = "json+deflate"

    /// Below this, framing overhead outweighs any saving.
    private static let compressionThreshold = 512

    struct Encoded {
        let data: Data
        let encoding: String
        /// Uncompressed byte count, required to size the decode buffer.
        let byteCount: Int
    }

    static func encode(_ payload: TraceJSON) throws -> Encoded {
        let raw = try payload.canonicalData()
        guard raw.count >= compressionThreshold,
              let compressed = deflate(raw),
              compressed.count < raw.count
        else {
            return Encoded(data: raw, encoding: plain, byteCount: raw.count)
        }
        return Encoded(data: compressed, encoding: deflated, byteCount: raw.count)
    }

    static func decode(data: Data, encoding: String, byteCount: Int) throws -> TraceJSON {
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
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return runCompression(
                    operation: operation,
                    destination: destinationBase,
                    destinationCapacity: capacity,
                    source: sourceBase,
                    sourceCount: input.count
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written...)
        return output
    }

    /// Thin shim over the two C entry points, which take identical arguments
    /// but are separate functions.
    private static func runCompression(
        operation: compression_stream_operation,
        destination: UnsafeMutablePointer<UInt8>,
        destinationCapacity: Int,
        source: UnsafePointer<UInt8>,
        sourceCount: Int
    ) -> Int {
        if operation == COMPRESSION_STREAM_ENCODE {
            return compression_encode_buffer(
                destination, destinationCapacity, source, sourceCount, nil, COMPRESSION_ZLIB
            )
        }
        return compression_decode_buffer(
            destination, destinationCapacity, source, sourceCount, nil, COMPRESSION_ZLIB
        )
    }
}
