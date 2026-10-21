import Foundation
import XCTest
import ZIPFoundation

final class ParakeetModelStoreTests: XCTestCase {
    private actor Downloads {
        let archive: URL
        var count = 0
        var status = 200
        var suspend = false
        init(_ archive: URL) { self.archive = archive }
        func setStatus(_ value: Int) { status = value }
        func setSuspended(_ value: Bool) { suspend = value }
        func fetch(_ url: URL) async throws -> (URL, URLResponse) {
            count += 1
            if suspend { try await Task.sleep(for: .seconds(60)) }
            await Task.yield()
            let temporary = archive.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: archive, to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("parakeet-redux-coreai")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("model.aimodel"), withIntermediateDirectories: true)
        try ParakeetTestData.configuration.write(to: bundle.appendingPathComponent("config.json"))
        try JSONEncoder().encode([String](repeating: "token", count: 8192)).write(to: bundle.appendingPathComponent("vocabulary.json"))
        // Installer tests validate packaging; inference is exercised separately.
        try Data("fixture MLIR payload".utf8).write(to: bundle.appendingPathComponent("model.aimodel/main.mlirb"))
        try Data(repeating: 1, count: 32).write(to: bundle.appendingPathComponent("model.aimodel/main.hash"))
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("model.aimodel/metadata.json"))
        let zip = root.appendingPathComponent("model.zip")
        try FileManager.default.zipItem(at: bundle, to: zip)
        return zip
    }

    func testConcurrentInstallAndOfflineCacheReuse() async throws {
        let root = try workspace()
        let requests = Downloads(try fixture(in: root))
        let cache = root.appendingPathComponent("cache")
        let store = ParakeetModelStore(root: cache, download: { try await requests.fetch($0) })
        async let first = store.directory()
        async let second = store.directory()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        let count = await requests.count
        XCTAssertEqual(count, 1)
        let offline = ParakeetModelStore(root: cache, download: { _ in throw URLError(.notConnectedToInternet) })
        let reused = try await offline.directory()
        XCTAssertEqual(reused, a)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["parakeet-redux-coreai"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("install-receipt.json").path))
    }

    func testTruncatedCacheIsDownloadedAgain() async throws {
        let root = try workspace()
        let requests = Downloads(try fixture(in: root))
        let store = ParakeetModelStore(root: root.appendingPathComponent("cache"), download: { try await requests.fetch($0) })
        let installed = try await store.directory()
        let payload = installed.appendingPathComponent("model.aimodel/main.mlirb")
        try Data([0]).write(to: payload)
        _ = try await store.directory()
        let count = await requests.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try Data(contentsOf: payload), Data("fixture MLIR payload".utf8))
    }

    func testHTTPFailureCanBeRetried() async throws {
        let root = try workspace()
        let requests = Downloads(try fixture(in: root))
        let cache = root.appendingPathComponent("cache")
        let store = ParakeetModelStore(root: cache, download: { try await requests.fetch($0) })
        await requests.setStatus(503)
        do {
            _ = try await store.directory()
            XCTFail("An HTTP error must not install a model")
        } catch ParakeetError.modelDownloadFailed(let status) { XCTAssertEqual(status, 503) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        await requests.setStatus(200)
        _ = try await store.directory()
        let count = await requests.count
        XCTAssertEqual(count, 2)
    }

    func testUnsafeArchivePathsAndSymlinksAreRejected() async throws {
        for (path, type) in [("../escaped", Entry.EntryType.file), ("link", .symlink)] {
            let root = try workspace()
            let zip = root.appendingPathComponent("unsafe.zip")
            do {
                let archive = try Archive(url: zip, accessMode: .create)
                let data = Data("../escaped".utf8)
                try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { offset, count in
                    data.subdata(in: Int(offset)..<(Int(offset) + count))
                }
            }
            let requests = Downloads(zip)
            let cache = root.appendingPathComponent("cache")
            let store = ParakeetModelStore(root: cache, download: { try await requests.fetch($0) })
            do {
                _ = try await store.directory()
                XCTFail("Unsafe archive must not be installed")
            } catch ParakeetError.invalidModelArchive { }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        }
    }

    func testCRCFailureDoesNotPublishAnInstallation() async throws {
        let root = try workspace()
        let zip = try fixture(in: root)
        var bytes = try Data(contentsOf: zip)
        let payload = try XCTUnwrap(bytes.range(of: Data("fixture MLIR payload".utf8)))
        bytes[payload.lowerBound] ^= 1
        try bytes.write(to: zip)
        let requests = Downloads(zip)
        let cache = root.appendingPathComponent("cache")
        let store = ParakeetModelStore(root: cache, download: { try await requests.fetch($0) })
        do {
            _ = try await store.directory()
            XCTFail("CRC failure must not install a model")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
    }

    func testCancelledDownloadCleansUpAndCanBeRetried() async throws {
        let root = try workspace()
        let requests = Downloads(try fixture(in: root))
        let cache = root.appendingPathComponent("cache")
        let store = ParakeetModelStore(root: cache, download: { try await requests.fetch($0) })
        await requests.setSuspended(true)
        let task = Task { try await store.directory() }
        for _ in 0..<100 {
            if await requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled download must throw") }
        catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
        await requests.setSuspended(false)
        _ = try await store.directory()
    }
}
