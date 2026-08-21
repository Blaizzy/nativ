import Foundation

struct VoiceTranscriptionConfiguration: Sendable {
    let modelSearchPath: String
    let additionalModelSearchPaths: [String]
    let selectedModelID: String?
    let languageModelID: String?
    let maxTokens: Int
    let serverBaseURL: URL
    let serverAPIKey: String?
    let serverIsRunning: Bool
}
