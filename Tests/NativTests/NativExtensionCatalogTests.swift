import Foundation
import NativExtensionSDK
import XCTest

final class NativExtensionCatalogTests: XCTestCase {
    private let sourceURL = URL(string: "https://example.com/catalog/v1/catalog.json")!

    func testCatalogDecodesAndValidates() throws {
        let catalog = try decodeCatalog()

        XCTAssertNoThrow(
            try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        )
        let entry = try XCTUnwrap(catalog.extensions.first)
        XCTAssertEqual(
            try entry.packageURL(relativeTo: sourceURL).absoluteString,
            "https://example.com/catalog/v1/packages/com.example.demo-1.0.0.zip"
        )
        XCTAssertTrue(entry.isCompatible(with: "0.4.0"))
        XCTAssertFalse(entry.isCompatible(with: "0.3.9"))
    }

    func testCatalogRejectsDuplicateIdentifiers() throws {
        let catalog = try decodeCatalog(extensionCount: 2)

        XCTAssertThrowsError(
            try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionCatalogError,
                .duplicateExtension("com.example.demo")
            )
        }
    }

    func testCatalogRejectsInvalidChecksum() throws {
        let catalog = try decodeCatalog(checksum: "not-a-checksum")

        XCTAssertThrowsError(
            try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionCatalogError,
                .invalidChecksum(extensionID: "com.example.demo")
            )
        }
    }

    func testCatalogRejectsNonWebHomepage() throws {
        let catalog = try decodeCatalog(homepage: "file:///tmp/extension.html")

        XCTAssertThrowsError(
            try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionCatalogError,
                .invalidHomepageURL(extensionID: "com.example.demo")
            )
        }
    }

    func testCatalogRejectsAbsoluteInstallURL() throws {
        let catalog = try decodeCatalog(installURL: "https://other.example/package.zip")

        XCTAssertThrowsError(
            try NativExtensionCatalogValidator.validate(catalog, sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionCatalogError,
                .invalidInstallURL(extensionID: "com.example.demo")
            )
        }
    }

    private func decodeCatalog(
        checksum: String = String(repeating: "a", count: 64),
        installURL: String = "packages/com.example.demo-1.0.0.zip",
        homepage: String = "https://example.com/demo",
        extensionCount: Int = 1
    ) throws -> NativExtensionCatalog {
        let entry =
            """
            {
              "id": "com.example.demo",
              "displayName": "Demo",
              "summary": "A declarative extension.",
              "developer": "Example",
              "homepage": "\(homepage)",
              "version": "1.0.0",
              "minimumNativVersion": "0.4.0",
              "category": "Developer",
              "systemImage": "puzzlepiece.extension",
              "runtime": "declarative",
              "status": "preview",
              "permissions": ["models.language"],
              "trust": "community",
              "publishedAt": "2026-09-03",
              "install": {
                "kind": "package",
                "url": "\(installURL)",
                "sha256": "\(checksum)",
                "bytes": 1024
              }
            }
            """
        let entries = Array(repeating: entry, count: extensionCount).joined(separator: ",")
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "extensions": [\(entries)]
            }
            """.utf8
        )
        return try JSONDecoder().decode(NativExtensionCatalog.self, from: data)
    }
}

final class NativExtensionCatalogPreferencesTests: XCTestCase {
    func testBlankOverrideUsesProductionCatalog() throws {
        XCTAssertEqual(
            try NativExtensionCatalogPreferences.sourceURL(override: "  "),
            NativExtensionCatalogPreferences.productionURL
        )
    }

    func testLocalHTTPOverrideIsAllowed() throws {
        XCTAssertEqual(
            try NativExtensionCatalogPreferences.sourceURL(
                override: "http://localhost:8000/catalog.json"
            ).absoluteString,
            "http://localhost:8000/catalog.json"
        )
    }

    func testRemoteHTTPOverrideIsRejected() {
        XCTAssertThrowsError(
            try NativExtensionCatalogPreferences.sourceURL(
                override: "http://example.com/catalog.json"
            )
        ) { error in
            XCTAssertEqual(
                error as? NativExtensionCatalogClientError,
                .invalidSourceURL
            )
        }
    }
}
