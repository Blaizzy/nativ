import Darwin
import Foundation

enum SafeLocalDirectoryReaderError: Error {
    case tooManyEntries
}

/// Descriptor-based directory reads use the same no-symlink traversal as the
/// native file reader. In particular, never enumerate a directory via a URL
/// after checking it: a symlink can replace that URL between those operations.
struct SafeLocalDirectoryReader {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let permissions: UInt16
        let modified: Date
    }

    func metadata(at url: URL) throws -> Entry {
        let descriptor = try open(url)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw failure() }
        return try entry(name: url.lastPathComponent, info: info)
    }

    func contents(of url: URL, maximumCount: Int = 10_000) throws -> [Entry] {
        let descriptor = try open(url)
        guard let directory = Darwin.fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw failure()
        }
        defer { Darwin.closedir(directory) }
        var result: [Entry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = Darwin.readdir(directory) else {
                guard errno == 0 else { throw failure() }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < maximumCount else {
                throw SafeLocalDirectoryReaderError.tooManyEntries
            }
            var info = stat()
            let status = name.withCString {
                Darwin.fstatat(descriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            // Disappearing entries, symlinks and special files are not traversed.
            guard status == 0, let value = try? entry(name: name, info: info) else { continue }
            result.append(value)
        }
        return result.sorted { $0.name < $1.name }
    }

    private func open(_ url: URL) throws -> Int32 {
        let components = url.pathComponents.filter { $0 != "/" }
        var descriptor = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure() }
        for (index, component) in components.enumerated() {
            let flags =
                O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW
                | (index < components.count - 1 ? O_DIRECTORY : 0)
            let next = component.withCString { Darwin.openat(descriptor, $0, flags) }
            Darwin.close(descriptor)
            guard next >= 0 else { throw failure() }
            descriptor = next
        }
        return descriptor
    }

    private func entry(name: String, info: stat) throws -> Entry {
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw failure() }
        return Entry(
            name: name, isDirectory: type == S_IFDIR, size: Int64(info.st_size),
            permissions: UInt16(info.st_mode & 0o777),
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        )
    }

    private func failure() -> Error {
        CocoaError(.fileReadNoPermission)
    }
}
