import XCTest
@testable import NativServerKit

@MainActor
final class NativRuntimeSettingsTests: XCTestCase {
    func testEditsWaitForReadinessAndCoalesce() async throws {
        let transport = SettingsTransport()
        let controller = NativRuntimeSettingsController(debounce: .milliseconds(1))
        controller.start(applied: ["apc_enabled": .bool(false)]) { try await transport.update($0) }
        controller.setDesired(["apc_enabled": .bool(true)])
        controller.setDesired(["apc_enabled": .bool(true), "apc_block_size": .number(32)])
        XCTAssertTrue(controller.hasPendingChanges)
        XCTAssertFalse(controller.isApplying)
        controller.serverBecameReady()
        try await finished(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests, [["apc_enabled": .bool(true), "apc_block_size": .number(32)]])
        XCTAssertFalse(controller.hasPendingChanges)
        XCTAssertNil(controller.errorMessage)
    }

    func testEditDuringRequestIsAppliedAfterAcknowledgement() async throws {
        let transport = SettingsTransport(delay: .milliseconds(50))
        let controller = NativRuntimeSettingsController(debounce: .milliseconds(1))
        controller.start(applied: ["apc_enabled": .bool(false)]) { try await transport.update($0) }
        controller.serverBecameReady()
        controller.setDesired(["apc_enabled": .bool(true)])
        while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        controller.setDesired(["apc_enabled": .bool(false)])
        try await finished(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests, [["apc_enabled": .bool(true)], ["apc_enabled": .bool(false)]])
        XCTAssertFalse(controller.hasPendingChanges)
    }

    func testLostResponseRequiresCorrectiveWriteEvenWhenReverted() async throws {
        let transport = SettingsTransport(failFirst: true)
        let controller = NativRuntimeSettingsController(debounce: .milliseconds(1))
        controller.start(applied: ["apc_enabled": .bool(false)]) { try await transport.update($0) }
        controller.serverBecameReady()
        controller.setDesired(["apc_enabled": .bool(true)])
        try await finished(controller)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.hasPendingChanges)
        controller.setDesired(["apc_enabled": .bool(false)])
        try await finished(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last, ["apc_enabled": .bool(false)])
        XCTAssertNil(controller.errorMessage)
    }

    func testPartialRejectionRemainsPendingAndRetrySendsOnlyUnappliedValues() async throws {
        let transport = SettingsTransport(rejectFirst: true)
        let controller = NativRuntimeSettingsController(debounce: .milliseconds(1))
        controller.start(applied: ["apc_enabled": .bool(false), "apc_block_size": .number(16)]) {
            try await transport.update($0)
        }
        controller.serverBecameReady()
        controller.setDesired(["apc_enabled": .bool(true), "apc_block_size": .number(32)])
        try await finished(controller)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(controller.hasPendingChanges)
        controller.retry()
        try await finished(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests.last, ["apc_block_size": .number(32)])
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.hasPendingChanges)
    }

    func testOldServerResponseCannotAcknowledgeNewServerSettings() async throws {
        let transport = SettingsTransport(delay: .milliseconds(50))
        let controller = NativRuntimeSettingsController(debounce: .milliseconds(1))
        controller.start(applied: ["apc_enabled": .bool(false)]) { try await transport.update($0) }
        controller.serverBecameReady()
        controller.setDesired(["apc_enabled": .bool(true)])
        while await transport.requests.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        controller.start(applied: ["apc_enabled": .bool(false)]) { try await transport.update($0) }
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.hasPendingChanges)
        controller.setDesired(["apc_enabled": .bool(true)])
        controller.serverBecameReady()
        try await finished(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testHTTPClientUsesAuthenticatedPatchNullsAndLegacyDraftNames() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuntimeSettingsURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["", "legacy"] {
            let client = NativRuntimeSettingsClient(
                baseURL: URL(string: "http://127.0.0.1:1234/\(path)")!, apiKey: "test-key", session: session
            )
            let result = try await client.update(["apc_enabled": .bool(true), "kv_bits": .null, "draft_model": .null])
            XCTAssertEqual(result.current["draft_model"], .null)
            XCTAssertEqual(result.current["apc_enabled"], .bool(true))
            XCTAssertTrue(result.rejected.isEmpty)
        }
        let missing = NativRuntimeSettingsClient(
            baseURL: URL(string: "http://127.0.0.1:1234/missing")!, apiKey: "test-key", session: session
        )
        do {
            _ = try await missing.update(["apc_enabled": .bool(true)])
            XCTFail("An unsupported endpoint must not look like success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("404"))
        }
    }

    private func finished(_ controller: NativRuntimeSettingsController) async throws {
        for _ in 0..<1000 {
            if !controller.isApplying { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Live settings did not finish")
    }
}

private actor SettingsTransport {
    var requests: [[String: MLXJSONValue]] = []
    var current: [String: MLXJSONValue] = [:]
    let delay: Duration
    let failFirst: Bool
    let rejectFirst: Bool

    init(delay: Duration = .zero, failFirst: Bool = false, rejectFirst: Bool = false) {
        self.delay = delay
        self.failFirst = failFirst
        self.rejectFirst = rejectFirst
    }

    func update(_ values: [String: MLXJSONValue]) async throws -> NativRuntimeSettingsResponse {
        requests.append(values)
        // Simulate a server that may finish applying a request after cancellation.
        try? await Task.sleep(for: delay)
        var accepted = values
        let reject = rejectFirst && requests.count == 1
        if reject { accepted.removeValue(forKey: "apc_block_size") }
        current.merge(accepted) { _, new in new }
        if failFirst && requests.count == 1 { throw URLError(.networkConnectionLost) }
        let body: [String: MLXJSONValue] = [
            "current": .object(current),
            "rejected": .array(reject ? [.object(["name": .string("apc_block_size"), "reason": .string("unsupported")])] : []),
        ]
        return try JSONDecoder().decode(NativRuntimeSettingsResponse.self, from: JSONEncoder().encode(body))
    }
}

private final class RuntimeSettingsURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertTrue(request.url!.path.hasSuffix("/v1/settings"))
            let legacy = request.url!.path.hasPrefix("/legacy/")
            let draftKey = legacy ? "spec_draft_model" : "draft_model"
            var current: [String: MLXJSONValue] = [draftKey: .null]
            if request.httpMethod == "PATCH" {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                current = try JSONDecoder().decode([String: MLXJSONValue].self, from: data)
                XCTAssertEqual(current[draftKey], .null)
                XCTAssertEqual(current["kv_bits"], .null)
                XCTAssertEqual(current["apc_enabled"], .bool(true))
            } else {
                XCTAssertEqual(request.httpMethod, "GET")
            }
            let body: [String: MLXJSONValue] = ["current": .object(current), "rejected": .array([])]
            let status = request.url!.path.hasPrefix("/missing/") ? 404 : 200
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
