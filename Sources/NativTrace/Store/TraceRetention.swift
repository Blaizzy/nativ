import Foundation

/// How much history to keep.
///
/// Both limits apply: whichever removes more wins. Age alone lets a heavy week
/// grow without bound; a count alone lets a trace from last year outlive its
/// usefulness because nothing newer arrived.
public struct TraceRetentionWindow: Sendable, Hashable {
    /// `nil` keeps every trace regardless of age.
    public var days: Int?
    /// `nil` keeps any number of traces.
    public var maximumTraces: Int?

    public static let `default` = TraceRetentionWindow(days: 30, maximumTraces: 500)
    /// Keeps nothing. Named for what it does, because `days: 0` reads like
    /// "no limit" while it means "older than now", i.e. everything.
    public static let clearAll = TraceRetentionWindow(days: 0, maximumTraces: 0)
    public static let unlimited = TraceRetentionWindow(days: nil, maximumTraces: nil)

    public init(days: Int?, maximumTraces: Int?) {
        self.days = days
        self.maximumTraces = maximumTraces
    }

    public func cutoff(from reference: Date) -> Date {
        guard let days else { return .distantPast }
        return reference.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }
}
