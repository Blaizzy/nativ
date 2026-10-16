import Foundation

public enum NativPrefillEvent: Equatable, Sendable {
    case started(requestID: String, totalTokens: Int)
    case advanced(requestID: String, processedTokens: Int, totalTokens: Int)
    case completed(requestID: String, totalTokens: Int?)
    case finished(requestID: String)
    case reset

    /// Consume the runtime's lifecycle messages, leaving ordinary server output alone.
    static func parse(_ line: String) -> Self? {
        let message: Substring
        let logParts = line.split(separator: " - ", maxSplits: 2, omittingEmptySubsequences: false)
        if logParts.count == 3, logParts[1] == "INFO" || logParts[1] == "ERROR" {
            message = logParts[2]
        } else {
            message = line[...]
        }
        let fields = message.split(whereSeparator: \.isWhitespace)
        func value(_ key: String) -> String? {
            fields.first(where: { $0.hasPrefix("\(key)=") })
                .map { String($0.dropFirst(key.count + 1)) }
        }

        if message.hasPrefix("Error in generation thread")
            || message.hasPrefix("Error in diffusion generation")
            || message.hasPrefix("Error in speculative generation thread") {
            return .reset
        }
        guard let requestID = value("request"), !requestID.isEmpty else { return nil }

        if message.hasPrefix("Prefill started:"),
           let total = value("prompt_tokens").flatMap(Int.init), total >= 0 {
            return .started(requestID: requestID, totalTokens: total)
        }
        if message.hasPrefix("Prefill progress:"), let tokens = value("tokens") {
            let counts = tokens.split(separator: "/", omittingEmptySubsequences: false)
            guard counts.count == 2,
                  let processed = Int(counts[0]), processed >= 0,
                  let total = Int(counts[1]), total >= 0 else { return nil }
            return .advanced(requestID: requestID, processedTokens: processed, totalTokens: total)
        }
        if message.hasPrefix("Prefill completed:") {
            return .completed(requestID: requestID, totalTokens: value("prompt_tokens").flatMap(Int.init))
        }
        if message.hasPrefix("Decode started:") || message.hasPrefix("Decode completed:") {
            return .completed(requestID: requestID, totalTokens: nil)
        }
        if message.hasPrefix("Generation cancelled:") {
            return .finished(requestID: requestID)
        }
        return nil
    }
}

public struct NativPrefillProgress: Equatable, Identifiable, Sendable {
    public let id: String
    public private(set) var processedTokens: Int
    public private(set) var totalTokens: Int
    fileprivate var completedAt: Date?

    public var isComplete: Bool { completedAt != nil }

    public var fractionCompleted: Double {
        if isComplete { return 1 }
        guard totalTokens > 0 else { return 0 }
        return min(max(Double(processedTokens) / Double(totalTokens), 0), 1)
    }

    fileprivate init(id: String, processedTokens: Int = 0, totalTokens: Int, completedAt: Date? = nil) {
        self.id = id
        self.processedTokens = min(max(processedTokens, 0), max(totalTokens, 0))
        self.totalTokens = max(totalTokens, 0)
        self.completedAt = completedAt
    }
}

/// Tracks requests separately so one request finishing cannot hide another's prefill.
public struct NativPrefillProgressState: Equatable, Sendable {
    public private(set) var requests: [NativPrefillProgress] = []

    public init() {}

    /// A single indicator for concurrent prefills, weighted by prompt size.
    public var fractionCompleted: Double {
        var completed = 0.0
        var total = 0.0
        for request in requests {
            let weight = Double(max(request.totalTokens, 1))
            completed += request.fractionCompleted * weight
            total += weight
        }
        return total > 0 ? min(max(completed / total, 0), 1) : 0
    }

    public mutating func apply(_ event: NativPrefillEvent, at date: Date = Date()) {
        switch event {
        case .started(let id, let total):
            update(NativPrefillProgress(id: id, totalTokens: total))
        case .advanced(let id, let processed, let total):
            update(NativPrefillProgress(id: id, processedTokens: processed, totalTokens: total))
        case .completed(let id, let reportedTotal):
            guard let previous = requests.first(where: { $0.id == id }), !previous.isComplete else { return }
            let total = max(reportedTotal ?? previous.totalTokens, 0)
            update(NativPrefillProgress(id: id, processedTokens: total, totalTokens: total, completedAt: date))
        case .finished(let id):
            requests.removeAll { $0.id == id }
        case .reset:
            requests.removeAll()
        }
    }

    /// Keep the filled bar visible briefly before removing it; never expire active requests.
    public mutating func removeCompleted(before date: Date) {
        requests.removeAll { $0.completedAt.map { $0 <= date } ?? false }
    }

    private mutating func update(_ progress: NativPrefillProgress) {
        if let index = requests.firstIndex(where: { $0.id == progress.id }) {
            requests[index] = progress
        } else {
            requests.append(progress)
        }
    }
}

/// Each stdout/stderr pipe gets its own buffer: reads may split or combine log lines.
final class NativPrefillOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var discardingLongLine = false
    private static let maximumLineBytes = 16_384

    func consume(_ data: Data) -> [NativPrefillEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [NativPrefillEvent] = []
        for byte in data {
            if byte == 10 {
                if !discardingLongLine,
                   let event = NativPrefillEvent.parse(String(decoding: pending, as: UTF8.self)) {
                    events.append(event)
                }
                pending.removeAll(keepingCapacity: true)
                discardingLongLine = false
            } else if !discardingLongLine {
                if pending.count < Self.maximumLineBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    discardingLongLine = true
                }
            }
        }
        return events
    }
}
