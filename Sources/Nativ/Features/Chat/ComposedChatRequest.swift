import NativServerKit
import NativTrace

/// A model call plus a description of how it was assembled.
///
/// The two travel together because provenance is only knowable at composition
/// time: once the system sections are joined and the tool definitions are
/// flattened into the request body, which skill contributed which paragraph and
/// which server supplied which tool is gone.
struct ComposedChatRequest {
    let request: MLXChatCompletionRequest
    /// `nil` when nothing is recording, so the work of describing the request
    /// is not done for a trace no one will read.
    let exposure: RequestComposedPayload?
}

extension SamplingParameters {
    /// Reads the settings off the request that carries them.
    ///
    /// Building this from `NativSettings` instead let the trace and the request
    /// disagree: the request gates `thinkingBudget` on speculative decoding and
    /// drops `responseFormat` when tools are advertised, and a parallel mapping
    /// did neither. Describing the request from the request removes the drift
    /// by construction rather than by discipline.
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
