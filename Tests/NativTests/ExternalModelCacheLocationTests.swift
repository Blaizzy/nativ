import XCTest

final class ExternalModelCacheLocationTests: XCTestCase {
    private let location = URL(fileURLWithPath: "/Volumes/Models/Nativ", isDirectory: true)

    func testAcceptsWritableExternalAPFSFolder() throws {
        let validatedLocation = try ExternalModelCacheLocation.validate(
            location,
            properties: properties()
        )

        XCTAssertEqual(validatedLocation, location)
    }

    func testRejectsInternalStorage() {
        assertValidationError(
            properties(isInternal: true),
            equals: .internalVolume
        )
    }

    func testAcceptsEjectableVolumeWhenInternalFlagIsUnavailable() throws {
        let validatedLocation = try ExternalModelCacheLocation.validate(
            location,
            properties: properties(isInternal: nil, isEjectable: true)
        )

        XCTAssertEqual(validatedLocation, location)
    }

    func testRejectsVolumeWithUnknownDeviceLocation() {
        assertValidationError(
            properties(isInternal: nil),
            equals: .unavailable
        )
    }

    func testRejectsNetworkStorage() {
        assertValidationError(
            properties(isLocal: false),
            equals: .networkVolume
        )
    }

    func testRejectsUnsupportedFileSystem() {
        assertValidationError(
            properties(fileSystemType: "exfat"),
            equals: .unsupportedFileSystem("exfat")
        )
    }

    func testRejectsReadOnlyStorage() {
        assertValidationError(
            properties(isReadOnly: true),
            equals: .readOnly
        )
    }

    func testRejectsFolderWithoutReadPermission() {
        assertValidationError(
            properties(isReadable: false),
            equals: .notReadable
        )
    }

    func testRejectsFolderWithoutWritePermission() {
        assertValidationError(
            properties(isWritable: false),
            equals: .notWritable
        )
    }

    func testRejectsAFile() {
        assertValidationError(
            properties(isDirectory: false),
            equals: .notDirectory
        )
    }

    func testReadsRealLocationProperties() throws {
        let temporaryFile = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data().write(to: temporaryFile)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }

        XCTAssertThrowsError(try ExternalModelCacheLocation.validate(temporaryFile)) {
            XCTAssertEqual(
                $0 as? ExternalModelCacheLocation.ValidationError,
                .notDirectory
            )
        }
    }

    private func properties(
        isDirectory: Bool = true,
        isReadable: Bool = true,
        isWritable: Bool = true,
        isLocal: Bool = true,
        isInternal: Bool? = false,
        isEjectable: Bool = false,
        isRemovable: Bool = false,
        isReadOnly: Bool = false,
        fileSystemType: String = "apfs"
    ) -> ExternalModelCacheLocation.VolumeProperties {
        ExternalModelCacheLocation.VolumeProperties(
            isDirectory: isDirectory,
            isReadable: isReadable,
            isWritable: isWritable,
            isLocal: isLocal,
            isInternal: isInternal,
            isEjectable: isEjectable,
            isRemovable: isRemovable,
            isReadOnly: isReadOnly,
            fileSystemType: fileSystemType
        )
    }

    private func assertValidationError(
        _ properties: ExternalModelCacheLocation.VolumeProperties,
        equals expectedError: ExternalModelCacheLocation.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ExternalModelCacheLocation.validate(location, properties: properties),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? ExternalModelCacheLocation.ValidationError,
                expectedError,
                file: file,
                line: line
            )
        }
    }
}
