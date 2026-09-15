import NativServerKit

struct ComposedChatRequest {
    let request: MLXChatCompletionRequest
    let exposure: RequestComposedPayload?
}

extension SamplingParameters {
    init(_ request: MLXChatCompletionRequest) {
        self.init(
            temperature: request.temperature,
            topP: request.topP,
            topK: request.topK,
            minP: request.minP,
            maxTokens: request.maxTokens,
            repetitionPenalty: request.repetitionPenalty,
            thinkingEnabled: request.enableThinking,
            thinkingBudget: request.thinkingBudget,
            toolChoice: request.toolChoice,
            responseFormat: request.responseFormat.flatMap { try? TraceJSON(encoding: $0) }
        )
    }
}
