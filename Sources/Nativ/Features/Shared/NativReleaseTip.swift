import OSLog
import TipKit

protocol NativReleaseTip: Tip {
    static var stableID: String { get }
}

extension NativReleaseTip {
    var id: String {
        Self.stableID
    }

    var options: [any TipOption] {
        [MaxDisplayCount(1)]
    }
}

enum NativReleaseTips {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nativ",
        category: "ReleaseTips"
    )

    static func configure() {
        do {
            #if DEBUG
            if CommandLine.arguments.contains("--reset-release-tips") {
                try Tips.resetDatastore()
            }
            #endif
            try Tips.configure([.displayFrequency(.daily)])
            #if DEBUG
            if CommandLine.arguments.contains("--show-all-release-tips") {
                Tips.showAllTipsForTesting()
            }
            #endif
        } catch {
            logger.error("Unable to configure release tips: \(error.localizedDescription, privacy: .public)")
        }
    }
}
