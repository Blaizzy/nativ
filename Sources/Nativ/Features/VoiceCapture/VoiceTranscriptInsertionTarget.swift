import Foundation

/// The application that was frontmost when text was captured, so a later
/// insertion can be aimed at it rather than at whatever is frontmost by then.
struct VoiceTranscriptInsertionTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let applicationName: String?

    init(processIdentifier: pid_t, applicationName: String? = nil) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
    }
}
