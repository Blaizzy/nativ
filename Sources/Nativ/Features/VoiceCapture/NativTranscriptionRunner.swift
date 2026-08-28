import Foundation
import NativServerKit

enum NativTranscriptionError: LocalizedError {
    case serverNotRunning
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            "Start Nativ's local model server before transcribing."
        case .modelUnavailable:
            "No speech-to-text model is installed."
        }
    }
}

struct NativTranscription: Sendable {
    let text: String
    let modelID: String
}

struct NativTranscriptionRunner: Sendable {
    let configuration: VoiceTranscriptionConfiguration

    func transcribe(
        audioData: Data,
        fileName: String,
        requestedModelID: String? = nil
    ) async throws -> NativTranscription {
        guard configuration.serverIsRunning else {
            throw NativTranscriptionError.serverNotRunning
        }
        let modelID = try await resolvedModelID(requestedModelID)
        let result = try await NativAudioClient(
            baseURL: configuration.serverBaseURL,
            apiKey: configuration.serverAPIKey
        )
        .transcribe(audioData: audioData, fileName: fileName, model: modelID)
        return NativTranscription(text: result.text, modelID: modelID)
    }

    func transcribe(
        fileURL: URL,
        requestedModelID: String? = nil
    ) async throws -> NativTranscription {
        try await transcribe(
            audioData: try Data(contentsOf: fileURL, options: .mappedIfSafe),
            fileName: fileURL.lastPathComponent,
            requestedModelID: requestedModelID
        )
    }

    private func resolvedModelID(_ requested: String?) async throws -> String {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return requested
        }
        let models = try await LocalModelDiscovery.scan(
            searchPaths: LocalModelSearchPaths(
                primary: configuration.modelSearchPath,
                additional: configuration.additionalModelSearchPaths
            )
        )
        guard let resolved = LocalModelDiscovery.speechToTextModelID(
            in: models,
            selectedModelID: configuration.selectedModelID
        ) else {
            throw NativTranscriptionError.modelUnavailable
        }
        return resolved
    }
}
