import Foundation
import NativExtensionSDK
import NativServerKit

private enum NativExtensionHostBrokerError: LocalizedError {
    case invalidRequest
    case extensionMismatch
    case permissionDenied(NativExtensionPermission)
    case unsupportedOperation(NativExtensionHostOperation)
    case unavailableConfiguration
    case serverNotRunning
    case speechModelUnavailable
    case invalidStorageKey
    case insertionFailed

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The extension sent an invalid request."
        case .extensionMismatch:
            "The request does not belong to the connected extension."
        case .permissionDenied(let permission):
            "The extension does not have permission to use \(permission.displayName)."
        case .unsupportedOperation(let operation):
            "The host operation \(operation.rawValue) is not implemented."
        case .unavailableConfiguration:
            "Nativ’s model configuration is unavailable."
        case .serverNotRunning:
            "The Nativ server is not running."
        case .speechModelUnavailable:
            "No compatible speech-to-text model is installed."
        case .invalidStorageKey:
            "The extension storage key is invalid."
        case .insertionFailed:
            "Nativ could not insert text at the cursor."
        }
    }
}

final class NativExtensionHostBroker:
    NSObject,
    NativExtensionHostXPCProtocol
{
    private let extensionID: String
    private let hostVersion: String
    private let grantedPermissions: Set<NativExtensionPermission>
    private let storageDirectory: URL
    private let transcriptionConfiguration:
        @MainActor () -> VoiceTranscriptionConfiguration?

    init(
        extensionID: String,
        hostVersion: String,
        grantedPermissions: Set<NativExtensionPermission>,
        storageDirectory: URL,
        transcriptionConfiguration:
            @escaping @MainActor () -> VoiceTranscriptionConfiguration?
    ) {
        self.extensionID = extensionID
        self.hostVersion = hostVersion
        self.grantedPermissions = grantedPermissions
        self.storageDirectory = storageDirectory
        self.transcriptionConfiguration = transcriptionConfiguration
    }

    func performHostRequest(
        _ requestData: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(
            NativExtensionHostRequest.self,
            from: requestData
        ) else {
            reply(nil, NativExtensionHostBrokerError.invalidRequest.localizedDescription)
            return
        }
        guard request.extensionID == extensionID else {
            reply(nil, NativExtensionHostBrokerError.extensionMismatch.localizedDescription)
            return
        }

        Task { @MainActor in
            do {
                let responsePayload = try await handle(request)
                let response = NativExtensionHostResponse(
                    requestID: request.requestID,
                    payload: responsePayload
                )
                reply(try JSONEncoder().encode(response), nil)
            } catch {
                let response = NativExtensionHostResponse(
                    requestID: request.requestID,
                    errorMessage: error.localizedDescription
                )
                reply(try? JSONEncoder().encode(response), error.localizedDescription)
            }
        }
    }

    @MainActor
    private func handle(_ request: NativExtensionHostRequest) async throws -> Data? {
        if let permission = requiredPermission(for: request.operation),
           !grantedPermissions.contains(permission) {
            throw NativExtensionHostBrokerError.permissionDenied(permission)
        }

        switch request.operation {
        case .hostInformation:
            return try JSONEncoder().encode(
                NativExtensionHostInformation(
                    hostVersion: hostVersion,
                    extensionID: extensionID,
                    grantedPermissions: grantedPermissions
                )
            )
        case .listModels:
            let configuration = try configuration()
            let models = try await LocalModelDiscovery.scan(
                path: configuration.modelSearchPath,
                additionalPaths: configuration.additionalModelSearchPaths
            )
            let descriptors = models.map {
                NativExtensionModelDescriptor(
                    id: $0.repoID,
                    displayName: $0.displayName,
                    capabilities: Set($0.capabilities.map(\.rawValue))
                )
            }
            return try JSONEncoder().encode(descriptors)
        case .transcribeAudio:
            guard let payload = request.payload,
                  let transcriptionRequest = try? JSONDecoder().decode(
                    NativExtensionTranscriptionRequest.self,
                    from: payload
                  ) else {
                throw NativExtensionHostBrokerError.invalidRequest
            }
            let configuration = try configuration()
            guard configuration.serverIsRunning else {
                throw NativExtensionHostBrokerError.serverNotRunning
            }
            let modelID: String
            if let requestedModelID = transcriptionRequest.modelID,
               !requestedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modelID = requestedModelID
            } else {
                let models = try await LocalModelDiscovery.scan(
                    path: configuration.modelSearchPath,
                    additionalPaths: configuration.additionalModelSearchPaths
                )
                guard let resolvedModelID = LocalModelDiscovery.speechToTextModelID(
                    in: models,
                    selectedModelID: configuration.selectedModelID
                ) else {
                    throw NativExtensionHostBrokerError.speechModelUnavailable
                }
                modelID = resolvedModelID
            }
            let result = try await NativAudioClient(
                baseURL: configuration.serverBaseURL,
                apiKey: configuration.serverAPIKey
            )
            .transcribe(
                audioData: transcriptionRequest.audioData,
                fileName: transcriptionRequest.fileName,
                model: modelID
            )
            return try JSONEncoder().encode(
                NativExtensionTranscriptionResponse(
                    text: result.text,
                    modelID: modelID
                )
            )
        case .insertText:
            guard let payload = request.payload,
                  let insertionRequest = try? JSONDecoder().decode(
                    NativExtensionTextInsertionRequest.self,
                    from: payload
                  ) else {
                throw NativExtensionHostBrokerError.invalidRequest
            }
            let target = VoiceTranscriptInserter.captureTarget()
            guard await VoiceTranscriptInserter.insertAtCursor(
                insertionRequest.text,
                target: target
            ) else {
                throw NativExtensionHostBrokerError.insertionFailed
            }
            return nil
        case .readStorage:
            let storageRequest = try decodeStorageRequest(request.payload)
            let storageURL = try storageURL(for: storageRequest.key)
            return try? Data(contentsOf: storageURL)
        case .writeStorage:
            let storageRequest = try decodeStorageRequest(request.payload)
            let storageURL = try storageURL(for: storageRequest.key)
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            if let data = storageRequest.data {
                try data.write(to: storageURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: storageURL.path) {
                try FileManager.default.removeItem(at: storageURL)
            }
            return nil
        case .registerShortcut, .presentOverlay:
            throw NativExtensionHostBrokerError.unsupportedOperation(request.operation)
        }
    }

    @MainActor
    private func configuration() throws -> VoiceTranscriptionConfiguration {
        guard let configuration = transcriptionConfiguration() else {
            throw NativExtensionHostBrokerError.unavailableConfiguration
        }
        return configuration
    }

    private func requiredPermission(
        for operation: NativExtensionHostOperation
    ) -> NativExtensionPermission? {
        switch operation {
        case .hostInformation:
            nil
        case .listModels, .transcribeAudio:
            .modelsSpeechToText
        case .registerShortcut:
            nil
        case .presentOverlay:
            .overlay
        case .insertText:
            .accessibilityInsertText
        case .readStorage, .writeStorage:
            .namespacedStorage
        }
    }

    private func decodeStorageRequest(
        _ payload: Data?
    ) throws -> NativExtensionStorageRequest {
        guard let payload,
              let request = try? JSONDecoder().decode(
                NativExtensionStorageRequest.self,
                from: payload
              ) else {
            throw NativExtensionHostBrokerError.invalidRequest
        }
        return request
    }

    private func storageURL(for key: String) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.")
        )
        guard !key.isEmpty,
              key != ".",
              key != "..",
              key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw NativExtensionHostBrokerError.invalidStorageKey
        }
        return storageDirectory.appendingPathComponent(key, isDirectory: false)
    }
}
