import Foundation
import XCTest

@MainActor
final class HuggingFaceDownloadCapacityTests: XCTestCase {
    func testConcurrentReservationsCannotOvercommitOneDisk() async {
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let admitted = await withTaskGroup(of: UUID?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let id = UUID()
                    do {
                        try capacity.reserve(id, bytes: 8, atPath: "/cache")
                        return id
                    } catch { return nil }
                }
            }
            var ids: [UUID] = []
            for await id in group { if let id { ids.append(id) } }
            return ids
        }
        XCTAssertEqual(admitted.count, 1)
        admitted.forEach { capacity.release($0) }
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: "/cache"))
    }

    func testGroupsDifferentPathsOnTheSameVolumeAndSeparatesOtherDisks() throws {
        let capacity = HuggingFaceDownloadCapacity { path in
            .init(volume: path == "/external" ? 2 : 1, freeBytes: 10)
        }
        let first = UUID()
        try capacity.reserve(first, bytes: 8, atPath: "/cache/a")
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 8, atPath: "/cache/b"))
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 8, atPath: "/external"))
        capacity.release(first)
        capacity.release(first) // Cleanup is idempotent.
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: "/cache/b"))
    }

    func testInvalidAndDuplicateRequestsCannotReplaceAnExistingReservation() throws {
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: .max) }
        let first = UUID()
        try capacity.reserve(first, bytes: .max, atPath: "/cache")
        XCTAssertThrowsError(try capacity.reserve(first, bytes: 0, atPath: "/cache"))
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 1, atPath: "/cache"))
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: -1, atPath: "/cache"))
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 0, atPath: "/cache"))
    }

    func testRealFileSystemLookupAndUnavailablePath() throws {
        let capacity = HuggingFaceDownloadCapacity()
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 0, atPath: NSTemporaryDirectory()))
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 1, atPath: "/nonexistent-\(UUID())"))
    }

    func testConcurrentSubprocessesResolveBeforeAdmissionAndOnlyOneStarts() async throws {
        let directory = try temporaryDirectory()
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let started = expectation(description: "one transfer admitted")
        let rejected = expectation(description: "other transfer rejected")
        let operations = (0..<2).map { index in
            operation(capacity: capacity, directory: directory, bytes: 8,
                      beforeResolution: """
                      open(os.path.join(sys.argv[2], 'ready-\(index)'), 'w').close()
                      while not all(os.path.exists(os.path.join(sys.argv[2], 'ready-' + str(i))) for i in range(2)):
                          time.sleep(0.01)
                      """,
                      afterApproval: """
                      while not os.path.exists(os.path.join(sys.argv[2], 'finish')):
                          time.sleep(0.01)
                      """, phase: { if $0 == .downloading { started.fulfill() } })
        }
        defer {
            operations.forEach { $0.cancel() }
            try? FileManager.default.removeItem(at: directory)
        }
        let tasks = operations.map { operation in
            Task.detached {
                do { try operation.run(); return true }
                catch { rejected.fulfill(); return false }
            }
        }
        await fulfillment(of: [started, rejected], timeout: 10)
        try Data().write(to: directory.appendingPathComponent("finish"))
        var successes = 0
        for task in tasks { if await task.value { successes += 1 } }
        XCTAssertEqual(successes, 1)
        // Successful and rejected attempts have both released their reservations.
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: directory.path))
    }

    func testPausedAttemptKeepsReservationUntilCancellationExits() async throws {
        let directory = try temporaryDirectory()
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let started = expectation(description: "transfer admitted")
        let download = operation(capacity: capacity, directory: directory, bytes: 8,
                                 afterApproval: "while True: time.sleep(0.01)",
                                 phase: { if $0 == .downloading { started.fulfill() } })
        defer { download.cancel(); try? FileManager.default.removeItem(at: directory) }
        let task = Task.detached { try download.run() }
        await fulfillment(of: [started], timeout: 5)
        download.pause()
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 8, atPath: directory.path))
        download.resume()
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 8, atPath: directory.path))
        download.pause()
        download.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: directory.path))
    }

    func testCancellationDuringSizeResolutionDoesNotLeakReservation() async throws {
        let directory = try temporaryDirectory()
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let preparing = expectation(description: "resolving size")
        let download = operation(capacity: capacity, directory: directory, bytes: 8,
                                 beforeResolution: "time.sleep(30)",
                                 phase: { if $0 == .preparing { preparing.fulfill() } })
        defer { download.cancel(); try? FileManager.default.removeItem(at: directory) }
        let task = Task.detached { try download.run() }
        await fulfillment(of: [preparing], timeout: 5)
        download.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: directory.path))
    }

    func testFailureAfterAdmissionReleasesCapacity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let download = operation(capacity: capacity, directory: directory, bytes: 8,
                                 afterApproval: "raise RuntimeError('simulated transfer failure')")
        do { try await Task.detached { try download.run() }.value; XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("simulated transfer failure")) }
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: directory.path))
    }

    func testCancellationWhileCapacityCheckIsRunningReleasesLateReservation() async throws {
        let directory = try temporaryDirectory()
        let checking = expectation(description: "capacity check is in flight")
        let resumeCheck = DispatchSemaphore(value: 0)
        let capacity = HuggingFaceDownloadCapacity { path in
            if path == directory.path {
                checking.fulfill()
                _ = resumeCheck.wait(timeout: .now() + 5)
            }
            return .init(volume: 1, freeBytes: 10)
        }
        let download = operation(capacity: capacity, directory: directory, bytes: 8)
        defer {
            resumeCheck.signal()
            download.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
        let task = Task.detached { try download.run() }
        await fulfillment(of: [checking], timeout: 5)
        download.cancel()
        await download.waitForExit(timeout: .seconds(2))
        resumeCheck.signal()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        // An approval delivered after the child exits must not crash or leak capacity.
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: "/after-cancellation"))
    }

    func testAdmissionReadsCurrentFreeSpaceAfterAnEarlierAttemptFinishes() throws {
        let capacity = HuggingFaceDownloadCapacity { path in
            .init(volume: 1, freeBytes: path == "/before-transfer" ? 10 : 2)
        }
        let first = UUID()
        try capacity.reserve(first, bytes: 8, atPath: "/before-transfer")
        capacity.release(first)
        XCTAssertThrowsError(try capacity.reserve(UUID(), bytes: 3, atPath: "/after-transfer"))
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 2, atPath: "/after-transfer"))
    }

    func testRetryResolvesAndReservesAgainAfterPreviousAttemptExits() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capacity = HuggingFaceDownloadCapacity { _ in .init(volume: 1, freeBytes: 10) }
        let retried = expectation(description: "stalled transfer retries")
        let download = operation(capacity: capacity, directory: directory, bytes: 8,
                                 beforeResolution: """
                                 if os.path.exists(os.path.join(sys.argv[2], 'attempted')):
                                     size = 10
                                 """,
                                 afterApproval: """
                                 if not os.path.exists(os.path.join(sys.argv[2], 'attempted')):
                                     open(os.path.join(sys.argv[2], 'attempted'), 'w').close()
                                     while True: time.sleep(0.01)
                                 """, stallTimeout: 0.2,
                                 phase: { if $0 == .retrying { retried.fulfill() } })
        defer { download.cancel() }
        let task = Task.detached { try download.run() }
        await fulfillment(of: [retried], timeout: 10)
        try await task.value
        XCTAssertNoThrow(try capacity.reserve(UUID(), bytes: 10, atPath: directory.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func operation(
        capacity: HuggingFaceDownloadCapacity, directory: URL, bytes: Int,
        beforeResolution: String = "pass", afterApproval: String = "pass",
        stallTimeout: TimeInterval = 60,
        phase: @escaping @Sendable (HuggingFaceDownloadManager.DownloadPhase) -> Void = { _ in }
    ) -> HuggingFaceDownloadOperation {
        let script = """
        import os, sys, time
        from types import SimpleNamespace
        ignored_patterns = ["*.[gG][gG][uU][fF]"]
        def snapshot_download(**kwargs):
            assert kwargs['dry_run'] is True
            size = \(bytes)
        \(beforeResolution.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
            return [SimpleNamespace(file_size=size, will_download=True, commit_hash='resolved-commit')]
        \(HuggingFaceDownloadPreflight.script)
        print('__NATIV_STAGE__:downloading', flush=True)
        \(afterApproval)
        """
        return HuggingFaceDownloadOperation(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, "org/model", directory.path, "0", "requested-commit"],
            environment: ProcessInfo.processInfo.environment,
            cachePath: directory.path, capacity: capacity, stallTimeout: stallTimeout, phase: phase
        )
    }
}
