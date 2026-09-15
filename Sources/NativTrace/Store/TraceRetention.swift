import Foundation

public struct TraceRetentionWindow: Sendable, Hashable {
    public var days: Int?
    public var maximumTraces: Int?

    public static let `default` = TraceRetentionWindow(days: 30, maximumTraces: 500)
    public static let clearAll = TraceRetentionWindow(days: 0, maximumTraces: 0)

    public init(days: Int?, maximumTraces: Int?) {
        self.days = days
        self.maximumTraces = maximumTraces
    }

    public func cutoff(from reference: Date) -> Date {
        guard let days else { return .distantPast }
        return reference.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}

