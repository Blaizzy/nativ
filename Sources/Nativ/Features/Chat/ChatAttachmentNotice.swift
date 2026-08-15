import Foundation

struct ChatAttachmentNotice: Identifiable, Equatable {
    enum Severity: Equatable {
        case progress
        case warning
        case error
    }

    let id: String
    let severity: Severity
    let title: String?
    let message: String
    let systemImage: String?
    let isDismissible: Bool

    init(
        id: String,
        severity: Severity,
        title: String? = nil,
        message: String,
        systemImage: String? = nil,
        isDismissible: Bool = false
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.isDismissible = isDismissible
    }
}
