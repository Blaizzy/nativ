import Foundation

struct ExternalModelCacheLocation {
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

    enum ValidationError: LocalizedError, Hashable, Identifiable {
        case unavailable
        case notDirectory
        case networkVolume
        case internalVolume
        case readOnly
        case notReadable
        case notWritable
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
            case .unsupportedFileSystem(let fileSystemType):
                "Only APFS external drives are supported in this release. The selected drive uses \(fileSystemType.uppercased())."
            }
        }
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
}
