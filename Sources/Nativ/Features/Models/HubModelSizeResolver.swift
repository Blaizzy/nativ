import Foundation

/// Resolves download bytes independently of tensor/memory estimates. Only callers
/// still interested in a row keep its queued or in-flight request alive.
@MainActor
final class HubModelSizeResolver {
    static let shared = HubModelSizeResolver()

    struct Request: Hashable, Sendable {
        let repoID: String
        let revision: String?
        let token: String?

        init(repoID: String, revision: String? = nil, token: String? = nil) {
            self.repoID = repoID
            self.revision = revision
            self.token = HuggingFaceAuthentication.normalizedToken(token)
        }
    }

    typealias Fetch = @Sendable (Request) async -> Data?

    private struct CachedSize {
        let bytes: Int64?
        let expires: Date
    }

    private final class Job {
        let request: Request
        var waiters: [UUID: CheckedContinuation<Int64?, Never>] = [:]
        var task: Task<Void, Never>?

        init(request: Request) { self.request = request }
    }

    private let maximumConcurrentRequests: Int
    private let debounce: Duration
    private let fetch: Fetch
    private var cache: [Request: CachedSize] = [:]
    private var jobs: [Request: Job] = [:]
    private var queue: [Job] = []
    private var activeRequests = 0

    init(maximumConcurrentRequests: Int = 4, debounce: Duration = .milliseconds(250),
         fetch: @escaping Fetch = HubModelSizeResolver.fetchMetadata) {
        precondition(maximumConcurrentRequests > 0)
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.debounce = debounce
        self.fetch = fetch
    }

    func cachedSize(for request: Request) -> Int64? {
        guard let cached = cache[request], cached.expires > .now else { return nil }
        return cached.bytes
    }

    func resolveSize(for repoID: String, revision: String? = nil, token: String? = nil) async -> Int64? {
        let request = Request(repoID: repoID, revision: revision, token: token)
        guard !Task.isCancelled else { return nil }
        if let cached = cache[request], cached.expires > .now { return cached.bytes }
        do { try await Task.sleep(for: debounce) } catch { return nil }
        guard !Task.isCancelled else { return nil }
        if let cached = cache[request], cached.expires > .now { return cached.bytes }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let job: Job
                if let existing = jobs[request] {
                    job = existing
                } else {
                    job = Job(request: request)
                    jobs[request] = job
                    queue.append(job)
                }
                job.waiters[waiterID] = continuation
                startQueuedRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(waiterID, request: request)
            }
        }
    }

    private func cancel(_ waiterID: UUID, request: Request) {
        guard let job = jobs[request] else { return }
        job.waiters.removeValue(forKey: waiterID)?.resume(returning: nil)
        guard job.waiters.isEmpty else { return }
        jobs[request] = nil
        queue.removeAll { $0 === job }
        // The slot is released when URLSession acknowledges cancellation.
        job.task?.cancel()
    }

    private func startQueuedRequests() {
        while activeRequests < maximumConcurrentRequests, !queue.isEmpty {
            let job = queue.removeFirst()
            activeRequests += 1
            let fetch = fetch
            job.task = Task { [weak self] in
                let bytes = await Self.fetchSize(job.request, fetch: fetch)
                guard let self else { return }
                self.activeRequests -= 1
                if self.jobs[job.request] === job {
                    self.jobs[job.request] = nil
                    if !Task.isCancelled {
                        // Bound memory; failures briefly back off rather than refetching
                        // every time a lazy row appears. Unspecified revisions expire sooner.
                        let lifetime: TimeInterval = bytes == nil ? 30 : (job.request.revision == nil ? 300 : 3_600)
                        if self.cache.count >= 512,
                           let oldest = self.cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                            self.cache[oldest] = nil
                        }
                        self.cache[job.request] = CachedSize(bytes: bytes, expires: .now.addingTimeInterval(lifetime))
                    }
                    for waiter in job.waiters.values { waiter.resume(returning: bytes) }
                    job.waiters.removeAll()
                }
                self.startQueuedRequests()
            }
        }
    }

    @concurrent
    private static func fetchSize(_ request: Request, fetch: Fetch) async -> Int64? {
        guard let data = await fetch(request), !Task.isCancelled else { return nil }
        return totalBytes(from: data)
    }

    nonisolated static func metadataRequest(for request: Request) -> URLRequest? {
        var components = URLComponents(string: "https://huggingface.co")
        components?.path = "/api/models/\(request.repoID)"
        if let revision = request.revision { components?.path += "/revision/\(revision)" }
        components?.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components?.url else { return nil }
        var result = URLRequest(url: url)
        result.timeoutInterval = 20
        HuggingFaceAuthentication.authorize(&result, token: request.token)
        return result
    }

    private nonisolated static func fetchMetadata(_ request: Request) async -> Data? {
        guard let urlRequest = metadataRequest(for: request),
              let (data, response) = try? await URLSession.shared.data(for: urlRequest),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    nonisolated static func totalBytes(from data: Data) -> Int64? {
        guard let payload = try? JSONDecoder().decode(SizePayload.self, from: data),
              let siblings = payload.siblings, !siblings.isEmpty else { return nil }
        var total: Int64 = 0
        for sibling in siblings where !HuggingFaceDownloadFilePolicy.shouldIgnore(path: sibling.rfilename) {
            // Missing sizes must never silently become zero and understate a download.
            guard let size = sibling.lfs?.size ?? sibling.size, size >= 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total > 0 ? total : nil
    }

    private struct SizePayload: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        let siblings: [Sibling]?
    }
}
