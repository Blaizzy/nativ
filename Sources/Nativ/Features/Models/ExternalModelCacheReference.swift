import Foundation

struct ExternalModelCacheReference: Codable, Equatable, Sendable {
    struct Resolved: Equatable, Sendable {
        let url: URL
        let reference: ExternalModelCacheReference
        let availableCapacity: Int64?
    }

    enum State: Equatable, Sendable {
        case systemDefault
        case available(path: String, availableCapacity: Int64?)
        case unavailable(path: String, reason: ValidationError)
    }

    enum SwitchError: LocalizedError, Equatable, Sendable {
        case downloadsInProgress
        case modelSwitchInProgress
        case serverCouldNotStop

        var errorDescription: String? {
            switch self {
            case .downloadsInProgress:
                "Finish or cancel active model downloads before changing model storage."
            case .modelSwitchInProgress:
                "Wait for the current model change to finish before changing model storage."
            case .serverCouldNotStop:
                "Nativ could not stop the model server. Try again after stopping it manually."
            }
        }
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
        self = try Self.resolve(url).reference
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
        var foundDifferentVolume = false
        var seenPaths = Set<String>()
        for candidate in [bookmarkedURL, lastKnownURL].compactMap({ $0 }) {
            let path = candidate.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }

            do {
                let url = try Self.validate(candidate)
                return try Self.makeResolved(
                    for: url,
                    expectedVolumeIdentifier: volumeIdentifier
                )
            } catch let error as ValidationError {
                if error == .differentVolume {
                    foundDifferentVolume = true
                } else {
                    lastError = error
                }
            } catch {
                lastError = .unavailable
            }
        }
        if foundDifferentVolume {
            throw ValidationError.differentVolume
        }
        throw lastError
    }

    static func resolve(_ selectedURL: URL) throws -> Resolved {
        try makeResolved(for: validate(selectedURL))
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

    static func path(_ path: String, isOnVolumeAt volumeURL: URL) -> Bool {
        let cachePath = URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL.path
        let volumePath = volumeURL.standardizedFileURL.path
        return cachePath == volumePath || cachePath.hasPrefix(volumePath + "/")
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

    private static func makeResolved(
        for url: URL,
        expectedVolumeIdentifier: String? = nil
    ) throws -> Resolved {
        let values = try url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        guard let volumeIdentifier = values.volumeUUIDString else {
            throw ValidationError.unavailable
        }
        guard expectedVolumeIdentifier == nil
                || volumeIdentifier == expectedVolumeIdentifier else {
            throw ValidationError.differentVolume
        }

        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            relativeTo: nil
        )
        let availableCapacity = [
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeAvailableCapacity.map(Int64.init),
        ]
        .compactMap { $0 }
        .max()
        let reference = Self(
            bookmarkData: bookmarkData,
            volumeIdentifier: volumeIdentifier
        )
        return Resolved(
            url: url,
            reference: reference,
            availableCapacity: availableCapacity
        )
    }
}
