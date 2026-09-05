import Foundation
import NativExtensionSDK
import NativServerKit

extension NativWorkflowServices {
    /// Wires the workflow operations to the app's real subsystems.
    ///
    /// Everything stateful is captured from `model` here rather than threaded
    /// through the runner, so the runner stays free of the host.
    @MainActor
    static func live(model: NativModel) -> NativWorkflowServices {
        NativWorkflowServices(
            readSelection: {
                NativTextSelectionAccess.read()
            },
            replaceSelection: { text, selection in
                await NativTextSelectionAccess.replace(text, selection: selection)
            },
            invokeModel: { request in
                try await invoke(request, model: model)
            }
        )
    }

    @MainActor
    private static func invoke(
        _ request: NativWorkflowModelRequest,
        model: NativModel
    ) async throws -> NativWorkflowModelResponse {
        guard request.task == .language else {
            throw NativWorkflowServiceError.taskNotSupported(request.task)
        }

        let installed = (try? await LocalModelDiscovery.scan(
            searchPaths: model.settings.localModelSearchPaths
        )) ?? []
        let resolution = NativTaskModelSelection.resolve(
            task: request.task,
            requested: request.requestedModel,
            pinned: model.settings.modelID(
                for: NativTaskModelSelection.preloadSlot(for: request.task)
            ),
            installed: installed
        )
        guard case .resolved(let modelID, let substitutedFor) = resolution else {
            throw NativWorkflowServiceError.noCompatibleModel(request.task)
        }

        guard let baseURL = await waitForServer(model: model) else {
            throw NativWorkflowServiceError.serverUnavailable
        }

        let settings = model.settings
        let client = NativChatClient(baseURL: baseURL, apiKey: settings.serverAPIKey)
        let completion = try await client.completeChat(
            MLXChatCompletionRequest(
                model: modelID,
                messages: [.init(role: "user", content: request.prompt)],
                maxTokens: request.maxTokens ?? settings.maxTokens,
                temperature: request.temperature ?? settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP
            )
        )

        let text = completion.content.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        )
        guard !text.isEmpty else {
            throw NativWorkflowServiceError.emptyResponse
        }
        return NativWorkflowModelResponse(text: text, substitutedModel: substitutedFor)
    }

    /// Mirrors `RoutineRunner.waitForServer`: a workflow can be triggered while
    /// the server is still coming up.
    @MainActor
    private static func waitForServer(
        model: NativModel,
        timeout: TimeInterval = 120
    ) async -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while model.activeServerBaseURL == nil, Date() < deadline {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return model.activeServerBaseURL
    }
}

enum NativWorkflowServiceError: LocalizedError, Equatable {
    case taskNotSupported(NativWorkflowModelTask)
    case noCompatibleModel(NativWorkflowModelTask)
    case serverUnavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .taskNotSupported(let task):
            "Nativ cannot run the “\(task.rawValue)” model task yet."
        case .noCompatibleModel(let task):
            "No installed model can handle “\(task.rawValue)”. Download one from Models."
        case .serverUnavailable:
            "The Nativ server is not running."
        case .emptyResponse:
            "The model returned nothing."
        }
    }
}
