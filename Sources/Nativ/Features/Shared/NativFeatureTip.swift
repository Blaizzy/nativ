import OSLog
import TipKit

protocol NativFeatureTip: Tip {}

extension NativFeatureTip {
    var options: [any TipOption] {
        [MaxDisplayCount(1)]
    }
}

enum NativFeatureTips {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Nativ",
        category: "FeatureTips"
    )

    static func configure() {
        do {
            #if DEBUG
            if CommandLine.arguments.contains("--reset-feature-tips") {
                try Tips.resetDatastore()
            }
            #endif
            try Tips.configure([.displayFrequency(.daily)])
            #if DEBUG
            if CommandLine.arguments.contains("--show-all-feature-tips") {
                Tips.showAllTipsForTesting()
            }
            #endif
        } catch {
            logger.error("Unable to configure feature tips: \(error.localizedDescription, privacy: .public)")
        }
    }
}
