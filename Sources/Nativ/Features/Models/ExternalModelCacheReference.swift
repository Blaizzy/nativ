import Foundation

struct ExternalModelCacheReference: Codable, Equatable, Sendable {
    struct Resolved: Equatable, Sendable {
        let url: URL
        let reference: ExternalModelCacheReference
    }

    enum ValidationError: LocalizedError, Equatable, Sendable {
        case unavailable
        case notDirectory
        case networkVolume
        case internalVolume
        case unsupportedFileSystem(String)
        case readOnly
        case notReadable
        case notWritable
        case differentVolume

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "The selected folder is unavailable. Make sure its drive is connected and try again."
            case .notDirectory:
                "Choose a folder for Nativ’s model storage."
            case .networkVolume:
                "Choose a folder on a locally attached drive. Network storage is not supported."
            case .internalVolume:
                "Choose a folder on an external drive."
            case .unsupportedFileSystem(let fileSystem):
                "Choose an APFS-formatted drive. The selected drive uses \(fileSystem.uppercased())."
            case .readOnly:
                "The selected drive is read-only."
            case .notReadable:
                "Nativ cannot read the selected folder."
            case .notWritable:
                "Nativ cannot write to the selected folder."
            case .differentVolume:
                "A different drive is mounted at the selected location."
            }
        }
    }

    let bookmarkData: Data
    let volumeIdentifier: String

    init(url: URL) throws {
        self = try Self.make(for: Self.validate(url))
    }

    func resolve(lastKnownPath: String) throws -> Resolved {
        var bookmarkIsStale = false
        let bookmarkedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        )
        let lastKnownURL = URL(filePath: lastKnownPath, directoryHint: .isDirectory)

        var lastError = ValidationError.unavailable
        var seenPaths = Set<String>()
        for candidate in [bookmarkedURL, lastKnownURL].compactMap({ $0 }) {
            let path = candidate.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }

            do {
                let url = try Self.validate(candidate)
                let reference = try Self.make(for: url)
                guard reference.volumeIdentifier == volumeIdentifier else {
                    throw ValidationError.differentVolume
                }
                return Resolved(url: url, reference: reference)
            } catch let error as ValidationError {
                lastError = error
            } catch {
                lastError = .unavailable
            }
        }
        throw lastError
    }

    static func validateForUse(
        path: String,
        expectedVolumeIdentifier: String?
    ) throws -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(filePath: expandedPath, directoryHint: .isDirectory)
        guard let expectedVolumeIdentifier else { return url.standardizedFileURL }

        let validatedURL = try validate(url)
        let actualVolumeIdentifier = try validatedURL.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString
        guard actualVolumeIdentifier == expectedVolumeIdentifier else {
            throw ValidationError.differentVolume
        }
        return validatedURL
    }

    static func validate(_ selectedURL: URL) throws -> URL {
        guard selectedURL.isFileURL else {
            throw ValidationError.unavailable
        }

        let url = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isReadableKey,
                .isWritableKey,
                .volumeIsLocalKey,
                .volumeIsInternalKey,
                .volumeIsEjectableKey,
                .volumeIsRemovableKey,
                .volumeIsReadOnlyKey,
                .volumeTypeNameKey,
            ])
        } catch {
            throw ValidationError.unavailable
        }

        guard let isDirectory = values.isDirectory,
              let isReadable = values.isReadable,
              let isWritable = values.isWritable,
              let isLocal = values.volumeIsLocal,
              let isReadOnly = values.volumeIsReadOnly,
              let fileSystem = values.volumeTypeName else {
            throw ValidationError.unavailable
        }

        guard isDirectory else { throw ValidationError.notDirectory }
        guard isLocal else { throw ValidationError.networkVolume }
        if values.volumeIsInternal == true {
            throw ValidationError.internalVolume
        }
        guard values.volumeIsInternal == false
                || values.volumeIsEjectable == true
                || values.volumeIsRemovable == true else {
            throw ValidationError.unavailable
        }
        guard fileSystem.caseInsensitiveCompare("apfs") == .orderedSame else {
            throw ValidationError.unsupportedFileSystem(fileSystem)
        }
        guard !isReadOnly else { throw ValidationError.readOnly }
        guard isReadable else { throw ValidationError.notReadable }
        guard isWritable else { throw ValidationError.notWritable }
        return url
    }

    private init(bookmarkData: Data, volumeIdentifier: String) {
        self.bookmarkData = bookmarkData
        self.volumeIdentifier = volumeIdentifier
    }

    private static func make(for url: URL) throws -> Self {
        let volumeIdentifier = try url.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString
        guard let volumeIdentifier else {
            throw ValidationError.unavailable
        }

        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            relativeTo: nil
        )
        return Self(
            bookmarkData: bookmarkData,
            volumeIdentifier: volumeIdentifier
        )
    }
}
