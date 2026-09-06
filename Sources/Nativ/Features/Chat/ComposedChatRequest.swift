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
    let exposure: RequestComposedPayload
}
