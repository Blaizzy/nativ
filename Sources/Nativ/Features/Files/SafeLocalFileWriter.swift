import Darwin
import Foundation

enum SafeLocalFileWriterError: Error, Equatable, Sendable {
    case notFound
    case alreadyExists
    case permissionDenied
    case unsupportedFileType
    case contentTooLarge(maximumBytes: Int)
    case ioFailure(Int32)
}

struct SafeLocalFileWriter: Sendable {
    static let defaultMaximumBytes = 10 * 1024 * 1024

    let maximumBytes: Int

    init(maximumBytes: Int = Self.defaultMaximumBytes) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func write(data: Data, to url: URL, overwrite: Bool = true) throws -> FileReadFileStamp {
        guard data.count <= maximumBytes else {
            throw SafeLocalFileWriterError.contentTooLarge(maximumBytes: maximumBytes)
        }
        try Task.checkCancellation()

        let (parent, name) = try openParent(of: url, createMissing: true)
        defer { Darwin.close(parent) }

        var existingMode: mode_t?
        let existing = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        if existing >= 0 {
            defer { Darwin.close(existing) }
            var info = stat()
            guard Darwin.fstat(existing, &info) == 0 else { throw Self.error(for: errno) }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw SafeLocalFileWriterError.unsupportedFileType
            }
            guard overwrite else { throw SafeLocalFileWriterError.alreadyExists }
            existingMode = info.st_mode & 0o777
        } else if errno != ENOENT {
            throw Self.error(for: errno)
        }

        let temporaryName = ".nativ-write-\(UUID().uuidString)"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw Self.error(for: errno) }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(parent, $0, 0) }
            }
        }

        if let existingMode {
            guard Darwin.fchmod(descriptor, existingMode) == 0 else {
                throw Self.error(for: errno)
            }
        } else {
            _ = Darwin.fchmod(descriptor, mode_t(0o644))
        }

        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.error(for: errno)
                }
                written += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw Self.error(for: errno) }
        let renameResult = temporaryName.withCString { temporaryPointer in
            name.withCString { namePointer in
                Darwin.renameat(parent, temporaryPointer, parent, namePointer)
            }
        }
        guard renameResult == 0 else { throw Self.error(for: errno) }
        shouldRemoveTemporary = false

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw Self.error(for: errno) }
        return Self.stamp(from: info)
    }

    func delete(url: URL) throws {
        let (parent, name) = try openParent(of: url, createMissing: false)
        defer { Darwin.close(parent) }

        let descriptor = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw Self.error(for: errno) }
        var info = stat()
        let status = Darwin.fstat(descriptor, &info)
        Darwin.close(descriptor)
        guard status == 0 else { throw Self.error(for: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw SafeLocalFileWriterError.unsupportedFileType
        }
        let result = name.withCString { Darwin.unlinkat(parent, $0, 0) }
        guard result == 0 else { throw Self.error(for: errno) }
    }

    func move(from source: URL, to destination: URL) throws {
        let (sourceParent, sourceName) = try openParent(of: source, createMissing: false)
        defer { Darwin.close(sourceParent) }
        let (destinationParent, destinationName) = try openParent(
            of: destination,
            createMissing: true
        )
        defer { Darwin.close(destinationParent) }

        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(destinationParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if destinationDescriptor >= 0 {
            Darwin.close(destinationDescriptor)
            throw SafeLocalFileWriterError.alreadyExists
        }
        guard errno == ENOENT else { throw Self.error(for: errno) }

        let result = sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                Darwin.renameat(
                    sourceParent,
                    sourcePointer,
                    destinationParent,
                    destinationPointer
                )
            }
        }
        guard result == 0 else { throw Self.error(for: errno) }
    }

    private func openParent(of url: URL, createMissing: Bool) throws -> (Int32, String) {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let name = components.last, !name.isEmpty else {
            throw SafeLocalFileWriterError.unsupportedFileType
        }

        var directory = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Self.error(for: errno) }

        for component in components.dropLast() {
            var next = component.withCString {
                Darwin.openat(
                    directory,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW
                )
            }
            if next < 0, errno == ENOENT, createMissing {
                let created = component.withCString { Darwin.mkdirat(directory, $0, 0o755) }
                guard created == 0 || errno == EEXIST else {
                    let failure = errno
                    Darwin.close(directory)
                    throw Self.error(for: failure)
                }
                next = component.withCString {
                    Darwin.openat(
                        directory,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NONBLOCK | O_NOFOLLOW
                    )
                }
            }
            guard next >= 0 else {
                let failure = errno
                Darwin.close(directory)
                throw Self.error(for: failure)
            }
            Darwin.close(directory)
            directory = next
        }
        return (directory, name)
    }

    private static func stamp(from info: stat) -> FileReadFileStamp {
        FileReadFileStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000
                &+ Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private static func error(for code: Int32) -> SafeLocalFileWriterError {
        switch code {
        case ENOENT, ENOTDIR: .notFound
        case EEXIST: .alreadyExists
        case EACCES, EPERM, EROFS: .permissionDenied
        case ELOOP, EISDIR, ENXIO, ENODEV: .unsupportedFileType
        default: .ioFailure(code)
        }
    }
}
