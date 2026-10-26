import Foundation
import NativServerKit

/// Resolves read-aloud independently of the server's model preload selections.
@MainActor
struct ChatSpeechPreparation {
    static let defaultModelID = "nativ-community/phonon"

    struct Model: Equatable {
        let id: String
        let isInstalled: Bool
    }

    var resolveModel: (NativSettings) async throws -> Model
    var downloadModel: (Model, NativSettings) async throws -> Void
    var prepareServer: (NativSettings) async throws -> Void

    static func selectModel(preferredModelID: String?, installedModels: [LocalModel]) -> Model {
        let speechModels = installedModels.filter { $0.capabilities.contains(.textToSpeech) }
        let selected = speechModels.first { $0.repoID == preferredModelID }
            ?? speechModels.sorted { $0.repoID < $1.repoID }.first
        return Model(id: selected?.repoID ?? defaultModelID, isInstalled: selected != nil)
    }

    static func resolveModel(for settings: NativSettings) async throws -> Model {
        let installed: [LocalModel]
        do {
            installed = try await LocalModelDiscovery.scan(searchPaths: settings.localModelSearchPaths)
        } catch LocalModelDiscoveryError.pathNotFound(_) {
            // A new cache is created by the downloader when no voice is installed.
            installed = []
        }
        try Task.checkCancellation()
        return selectModel(preferredModelID: settings.textToSpeechModelID, installedModels: installed)
    }

    static func automatic(using appModel: NativModel) -> Self {
        Self(
            resolveModel: resolveModel(for:),
            downloadModel: { model, settings in
                try await HuggingFaceDownloadManager.shared.downloadIfNeeded(
                    repoID: model.id,
                    sizeBytes: nil,
                    cachePath: settings.modelSearchPath,
                    volumeIdentifier: settings.externalModelCache?.volumeIdentifier,
                    token: appModel.effectiveHuggingFaceToken
                )
            },
            prepareServer: { settings in
                try Task.checkCancellation()
                if !appModel.isRunning { appModel.startServer() }
                guard appModel.isRunning else { throw PreparationError.serverUnavailable }

                let client = NativMetricsClient(baseURL: settings.serverBaseURL, timeout: 2)
                let deadline = ContinuousClock.now.advanced(by: .seconds(180))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard appModel.isRunning else { throw PreparationError.serverUnavailable }
                    do {
                        _ = try await client.fetchMetrics(apiKey: settings.serverAPIKey)
                        return
                    } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(error.code) {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
                throw PreparationError.serverUnavailable
            }
        )
    }

    private enum PreparationError: LocalizedError {
        case serverUnavailable

        var errorDescription: String? {
            "The speech service could not start. Try reading aloud again."
        }
    }
}
