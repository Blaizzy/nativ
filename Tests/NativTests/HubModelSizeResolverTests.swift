import Foundation
import XCTest

@MainActor
final class HubModelSizeResolverTests: XCTestCase {
    func testCountsAllSelectedFormatsAndUsesLFSBytes() throws {
        let data = Data(#"{"siblings":[{"rfilename":"model.safetensors","size":12,"lfs":{"size":100}},{"rfilename":"pytorch_model.bin","size":100},{"rfilename":"onnx/model.onnx","size":100},{"rfilename":"tokenizer.json","size":5},{"rfilename":"optional.GgUf"}]}"#.utf8)
        XCTAssertEqual(HubModelSizeResolver.totalBytes(from: data), 305)
    }

    func testIncompleteInvalidOrOverflowingMetadataNeverBecomesAnExactSize() {
        for json in [
            #"{"siblings":[{"rfilename":"model.safetensors","size":100},{"rfilename":"tokenizer.json"}]}"#,
            #"{"siblings":[{"rfilename":"model.safetensors","size":-1}]}"#,
            #"{"siblings":[{"rfilename":"a","size":9223372036854775807},{"rfilename":"b","size":1}]}"#,
            #"{"siblings":[]}"#, #"{}"#, "not-json",
        ] {
            XCTAssertNil(HubModelSizeResolver.totalBytes(from: Data(json.utf8)))
        }
    }

    func testRequestUsesRevisionAndAuthentication() throws {
        let request = try XCTUnwrap(HubModelSizeResolver.metadataRequest(for: .init(
            repoID: "org/model", revision: "abcdef", token: " test-token \n"
        )))
        XCTAssertEqual(request.url?.path, "/api/models/org/model/revision/abcdef")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query, "blobs=true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testBoundsConcurrentLookups() async {
        let probe = SizeFetchProbe()
        let resolver = HubModelSizeResolver(maximumConcurrentRequests: 3, debounce: .zero) { await probe.fetch($0) }
        let results = await withTaskGroup(of: Int64?.self) { group in
            for index in 0..<12 {
                group.addTask { await resolver.resolveSize(for: "org/\(index)") }
            }
            var result: [Int64?] = []
            for await size in group { result.append(size) }
            return result
        }
        XCTAssertEqual(results.compactMap { $0 }, Array(repeating: Int64(105), count: 12))
        let maximum = await probe.maximumConcurrency
        XCTAssertEqual(maximum, 3)
    }

    func testSharesRequestsAndCachesByRevisionAndCredential() async {
        let probe = SizeFetchProbe()
        let resolver = HubModelSizeResolver(debounce: .zero) { await probe.fetch($0) }
        async let first = resolver.resolveSize(for: "org/model", revision: "a")
        async let second = resolver.resolveSize(for: "org/model", revision: "a")
        let sizes = await [first, second]
        XCTAssertEqual(sizes, [105, 105])
        _ = await resolver.resolveSize(for: "org/model", revision: "a")
        let cachedCount = await probe.calls
        XCTAssertEqual(cachedCount, 1)
        _ = await resolver.resolveSize(for: "org/model", revision: "b")
        _ = await resolver.resolveSize(for: "org/model", revision: "b", token: "other-user")
        let count = await probe.calls
        XCTAssertEqual(count, 3)
    }

    func testCancellingOneSubscriberDoesNotCancelSharedRequest() async throws {
        let probe = SizeFetchProbe()
        let resolver = HubModelSizeResolver(debounce: .zero) { await probe.fetch($0) }
        let first = Task { await resolver.resolveSize(for: "org/model") }
        let second = Task { await resolver.resolveSize(for: "org/model") }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        let firstSize = await first.value
        let secondSize = await second.value
        XCTAssertNil(firstSize)
        XCTAssertEqual(secondSize, 105)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancelledQueuedRowsDoNotFetchOrOccupySlots() async throws {
        let probe = SizeFetchProbe()
        let resolver = HubModelSizeResolver(maximumConcurrentRequests: 1, debounce: .zero) { await probe.fetch($0) }
        let first = Task { await resolver.resolveSize(for: "org/first") }
        try await Task.sleep(for: .milliseconds(5))
        let queued = Task { await resolver.resolveSize(for: "org/queued") }
        try await Task.sleep(for: .milliseconds(5))
        queued.cancel()
        let cancelled = await queued.value
        XCTAssertNil(cancelled)
        _ = await first.value
        let next = await resolver.resolveSize(for: "org/next")
        XCTAssertEqual(next, 105)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testFailedLookupsBackOffWithoutReportingPartialBytes() async {
        let probe = SizeFetchProbe(fails: true)
        let resolver = HubModelSizeResolver(debounce: .zero) { await probe.fetch($0) }
        let first = await resolver.resolveSize(for: "org/model")
        let second = await resolver.resolveSize(for: "org/model")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
}

private actor SizeFetchProbe {
    let fails: Bool
    private(set) var calls = 0
    private(set) var maximumConcurrency = 0
    private var active = 0

    init(fails: Bool = false) { self.fails = fails }

    func fetch(_ request: HubModelSizeResolver.Request) async -> Data? {
        calls += 1
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: .milliseconds(40)) } catch { return nil }
        return fails ? nil : Data(#"{"siblings":[{"rfilename":"model.safetensors","size":100},{"rfilename":"tokenizer.json","size":5}]}"#.utf8)
    }
}
