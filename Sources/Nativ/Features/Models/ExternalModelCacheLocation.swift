import Foundation

struct ExternalModelCacheLocation {
    struct Reference: Equatable, Sendable {
        let url: URL
        let bookmarkData: Data
        let volumeIdentifier: String
        let availableCapacity: Int64?
    }

    enum State: Equatable, Sendable {
        case systemDefault
        case available(path: String, availableCapacity: Int64?)
        case unavailable(path: String, reason: ValidationError)
    }

    struct VolumeProperties: Equatable, Sendable {
        let isDirectory: Bool
        let isReadable: Bool
        let isWritable: Bool
        let isLocal: Bool
        let isInternal: Bool?
        let isEjectable: Bool
        let isRemovable: Bool
        let isReadOnly: Bool
        let fileSystemType: String
    }

    enum ValidationError: LocalizedError, Hashable, Identifiable, Sendable {
        case unavailable
        case notDirectory
        case networkVolume
        case internalVolume
        case readOnly
        case notReadable
        case notWritable
        case differentVolume
        case downloadsInProgress
        case unsupportedFileSystem(String)

        var id: Self { self }

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "The selected folder is unavailable. Make sure its drive is connected and try again."
            case .notDirectory:
                "Choose a folder for Nativ’s model storage."
            case .networkVolume:
                "Choose a folder on a locally attached drive. Network storage is not supported."
            case .internalVolume:
                "Choose a folder on an external drive. The selected folder is on this Mac’s internal storage."
            case .readOnly:
                "The selected drive is read-only. Choose a drive that Nativ can write to."
            case .notReadable:
                "Nativ cannot read the selected folder. Check its permissions or choose another folder."
            case .notWritable:
                "Nativ cannot write to the selected folder. Check its permissions or choose another folder."
            case .differentVolume:
                "A different drive is mounted at the selected location. Reconnect the original drive or choose another location."
            case .downloadsInProgress:
                "Finish or cancel active model downloads before changing the model-storage location."
            case .unsupportedFileSystem(let fileSystemType):
                "Only APFS external drives are supported in this release. The selected drive uses \(fileSystemType.uppercased())."
            }
        }
    }

    static func makeReference(for selectedURL: URL) throws -> Reference {
        let url = try validate(selectedURL)
        return try makeReference(for: url, expectedVolumeIdentifier: nil)
    }

    static func resolve(
        bookmarkData: Data,
        expectedVolumeIdentifier: String,
        lastKnownPath: String
    ) throws -> Reference {
        var candidates: [URL] = []
        var bookmarkIsStale = false
        if let bookmarkedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkIsStale
        ) {
            candidates.append(bookmarkedURL)
        }

        let lastKnownURL = URL(
            fileURLWithPath: NSString(string: lastKnownPath).expandingTildeInPath,
            isDirectory: true
        )
        if !candidates.contains(where: { $0.standardizedFileURL == lastKnownURL.standardizedFileURL }) {
            candidates.append(lastKnownURL)
        }

        var identityError: ValidationError?
        var validationError: ValidationError?
        for candidate in candidates {
            do {
                let url = try validate(candidate)
                return try makeReference(
                    for: url,
                    expectedVolumeIdentifier: expectedVolumeIdentifier
                )
            } catch let error as ValidationError {
                if error == .differentVolume {
                    identityError = error
                } else if validationError == nil {
                    validationError = error
                }
            } catch {
                continue
            }
        }

        throw identityError ?? validationError ?? ValidationError.unavailable
    }

    static func validateForUse(
        path: String,
        expectedVolumeIdentifier: String?
    ) throws -> URL {
        let url = URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        guard let expectedVolumeIdentifier else {
            return url
        }

        let validatedURL = try validate(url)
        let values = try validatedURL.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard values.volumeUUIDString == expectedVolumeIdentifier else {
            throw ValidationError.differentVolume
        }
        return validatedURL
    }

    static func path(_ path: String, isOnVolumeAt volumeURL: URL) -> Bool {
        let cachePath = URL(fileURLWithPath: path, isDirectory: true)
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
              let fileSystemType = values.volumeTypeName else {
            throw ValidationError.unavailable
        }

        return try validate(
            url,
            properties: VolumeProperties(
                isDirectory: isDirectory,
                isReadable: isReadable,
                isWritable: isWritable,
                isLocal: isLocal,
                isInternal: values.volumeIsInternal,
                isEjectable: values.volumeIsEjectable == true,
                isRemovable: values.volumeIsRemovable == true,
                isReadOnly: isReadOnly,
                fileSystemType: fileSystemType
            )
        )
    }

    static func validate(_ url: URL, properties: VolumeProperties) throws -> URL {
        guard properties.isDirectory else {
            throw ValidationError.notDirectory
        }
        guard properties.isLocal else {
            throw ValidationError.networkVolume
        }
        let isInternal: Bool
        if let reportedValue = properties.isInternal {
            isInternal = reportedValue
        } else if properties.isEjectable || properties.isRemovable {
            isInternal = false
        } else {
            throw ValidationError.unavailable
        }
        guard !isInternal else {
            throw ValidationError.internalVolume
        }
        guard properties.fileSystemType.caseInsensitiveCompare("apfs") == .orderedSame else {
            throw ValidationError.unsupportedFileSystem(properties.fileSystemType)
        }
        guard !properties.isReadOnly else {
            throw ValidationError.readOnly
        }
        guard properties.isReadable else {
            throw ValidationError.notReadable
        }
        guard properties.isWritable else {
            throw ValidationError.notWritable
        }
        return url
    }

    private static func makeReference(
        for url: URL,
        expectedVolumeIdentifier: String?
    ) throws -> Reference {
        let values = try url.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        guard let volumeIdentifier = values.volumeUUIDString else {
            throw ValidationError.unavailable
        }
        if let expectedVolumeIdentifier,
           volumeIdentifier != expectedVolumeIdentifier {
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
        return Reference(
            url: url,
            bookmarkData: bookmarkData,
            volumeIdentifier: volumeIdentifier,
            availableCapacity: availableCapacity
        )
    }
}
