import AppKit
import SwiftUI

private struct ChatFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var chatFontScale: Double {
        get { self[ChatFontScaleKey.self] }
        set { self[ChatFontScaleKey.self] = newValue }
    }
}

enum ChatFontMetrics {
    static var baseBodyPointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    static func bodyFont(scale: Double) -> Font {
        .system(size: baseBodyPointSize * scale)
    }

    static func bodyNSFont(scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: baseBodyPointSize * scale)
    }
}
