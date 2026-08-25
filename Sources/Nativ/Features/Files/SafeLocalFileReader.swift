import Darwin
import Foundation

struct FileReadFileStamp: Equatable, Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedNanoseconds: Int64
}

struct SafeLocalFileSnapshot: Sendable {
    let data: Data
    let openedURL: URL
    let stamp: FileReadFileStamp
}

enum SafeLocalFileReaderError: Error, Equatable, Sendable {
    case notFound
    case permissionDenied
    case unsupportedFileType
    case fileTooLarge(maximumBytes: Int)
    case changedDuringRead
    case ioFailure(Int32)
}

struct SafeLocalFileReader: Sendable {
    static let defaultMaximumBytes = 50 * 1024 * 1024

    let maximumBytes: Int

    init(maximumBytes: Int = Self.defaultMaximumBytes) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func read(url: URL) async throws -> SafeLocalFileSnapshot {
        try Task.checkCancellation()

        let descriptor = Self.openWithoutFollowingSymlinks(url)
        guard descriptor >= 0 else {
            throw Self.error(for: errno)
        }
        defer { Darwin.close(descriptor) }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
            throw Self.error(for: errno)
        }
        guard fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw SafeLocalFileReaderError.unsupportedFileType
        }
        guard fileInfo.st_size >= 0,
              fileInfo.st_size <= off_t(maximumBytes) else {
            throw SafeLocalFileReaderError.fileTooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(fileInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.error(for: errno)
            }
            guard data.count + count <= maximumBytes else {
                throw SafeLocalFileReaderError.fileTooLarge(maximumBytes: maximumBytes)
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        var finalInfo = stat()
        guard Darwin.fstat(descriptor, &finalInfo) == 0 else {
            throw Self.error(for: errno)
        }
        let initialStamp = Self.stamp(from: fileInfo)
        let finalStamp = Self.stamp(from: finalInfo)
        guard initialStamp == finalStamp, finalStamp.size == data.count else {
            throw SafeLocalFileReaderError.changedDuringRead
        }

        return SafeLocalFileSnapshot(
            data: data,
            openedURL: url,
            stamp: finalStamp
        )
    }

    private static func stamp(from info: stat) -> FileReadFileStamp {
        let seconds = Int64(info.st_mtimespec.tv_sec)
        let nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        return FileReadFileStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedNanoseconds: seconds &* 1_000_000_000 &+ nanoseconds
        )
    }

    private static func openWithoutFollowingSymlinks(_ url: URL) -> Int32 {
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else {
            return Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }

        var directoryDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { return directoryDescriptor }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString { pointer in
                Darwin.openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                let failure = errno
                Darwin.close(directoryDescriptor)
                errno = failure
                return -1
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let descriptor = components.last!.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
            )
        }
        let failure = errno
        Darwin.close(directoryDescriptor)
        errno = failure
        return descriptor
    }

    private static func error(for code: Int32) -> SafeLocalFileReaderError {
        switch code {
        case ENOENT, ENOTDIR:
            .notFound
        case EACCES, EPERM:
            .permissionDenied
        case ELOOP, ENXIO, ENODEV:
            .unsupportedFileType
        default:
            .ioFailure(code)
        }
    }
}
