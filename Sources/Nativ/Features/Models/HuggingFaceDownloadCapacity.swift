import Foundation

/// Admission control shared by all downloader subprocesses in this app.
/// Every read/check/reserve happens under one lock, after the Hub dry run.
final class HuggingFaceDownloadCapacity: @unchecked Sendable {
    static let shared = HuggingFaceDownloadCapacity()

    struct Snapshot: Sendable {
        let volume: UInt64
        let freeBytes: Int64
    }

    enum Failure: LocalizedError {
        case unavailable
        case invalidReservation
        case insufficientSpace(required: Int64, available: Int64)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Could not verify available disk space. Try again."
            case .invalidReservation:
                return "Could not verify the model's disk reservation. Try again."
            case let .insufficientSpace(required, available):
                let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return "Model needs \(needed) of additional space, but only \(free) is available after reserving other downloads."
            }
        }
    }

    private struct Reservation {
        let volume: UInt64
        let bytes: Int64
    }

    private let lock = NSLock()
    private let readCapacity: @Sendable (String) throws -> Snapshot
    private var reservations: [UUID: Reservation] = [:]

    init(readCapacity: @escaping @Sendable (String) throws -> Snapshot = readFileSystem) {
        self.readCapacity = readCapacity
    }

    func reserve(_ id: UUID, bytes: Int64, atPath path: String) throws {
        try lock.withLock {
            guard bytes >= 0, reservations[id] == nil else {
                throw Failure.invalidReservation
            }
            // Read fresh free space inside the critical section. In particular,
            // do not use a snapshot taken before another request was admitted.
            let snapshot = try readCapacity(path)
            guard snapshot.freeBytes >= 0 else { throw Failure.unavailable }
            let available = reservations.values.reduce(snapshot.freeBytes) { free, reservation in
                reservation.volume == snapshot.volume ? max(free - reservation.bytes, 0) : free
            }
            guard bytes <= available else {
                throw Failure.insufficientSpace(required: bytes, available: available)
            }
            reservations[id] = Reservation(volume: snapshot.volume, bytes: bytes)
        }
    }

    func release(_ id: UUID) {
        lock.withLock { _ = reservations.removeValue(forKey: id) }
    }

    private static func readFileSystem(atPath path: String) throws -> Snapshot {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let free = attributes[.systemFreeSize] as? NSNumber else {
            throw Failure.unavailable
        }
        return Snapshot(volume: volume.uint64Value, freeBytes: free.int64Value)
    }
}
