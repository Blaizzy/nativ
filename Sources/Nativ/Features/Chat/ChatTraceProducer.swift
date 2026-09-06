import Foundation
import NativTrace

/// Translates chat activity into trace events.
///
/// A thin typed adapter: every method turns app values into a payload and hands
/// it to `TraceEventQueue`, which owns the "never block, never reorder"
/// guarantee. Keeping the queue in the framework means this type has no
/// concurrency logic of its own to get wrong.
@MainActor
final class ChatTraceProducer {
    private let queue: TraceEventQueue

    init(recorder: TraceRecorder) {
        queue = TraceEventQueue(recorder: recorder)
    }

    // MARK: - Session and turn

    func sessionStarted(sessionID: UUID, title: String?, modelID: String?) {
        queue.record(
            SessionStartedPayload(title: title, modelID: modelID),
            traceID: Self.traceID(for: sessionID),
            scope: TraceScope(sessionID: sessionID.uuidString, modelID: modelID)
        )
    }

    func turnStarted(
        _ turn: ChatTraceTurn,
        messageID: UUID,
        text: String,
        attachmentSummaries: [String] = [],
        modelID: String?
    ) {
        record(
            TurnStartedPayload(
                messageID: messageID.uuidString,
                text: text,
                attachmentSummaries: attachmentSummaries.isEmpty ? nil : attachmentSummaries
            ),
            turn: turn,
            modelID: modelID
        )
    }

    func turnEnded(_ turn: ChatTraceTurn, status: String, roundCount: Int) {
        record(TurnEndedPayload(status: status, roundCount: roundCount), turn: turn)
    }

    func modelSwitched(_ turn: ChatTraceTurn, from: String?, to: String) {
        record(ModelSwitchedPayload(from: from, to: to), turn: turn, modelID: to)
    }

    // MARK: - Calls

    func requestComposed(_ exposure: RequestComposedPayload, in call: ChatTraceCall) {
        record(exposure, call: call)
    }

    func delta(content: String?, reasoning: String?, in call: ChatTraceCall) {
        queue.delta(
            content: content,
            reasoning: reasoning,
            traceID: Self.traceID(for: call.sessionID),
            scope: call.scope()
        )
    }

    func responseCompleted(
        messageID: UUID,
        content: String,
        reasoning: String?,
        usage: TraceUsage?,
        finishReason: String?,
        in call: ChatTraceCall
    ) {
        queue.discardPartial(traceID: Self.traceID(for: call.sessionID), scope: call.scope())
        record(
            ResponseCompletedPayload(
                messageID: messageID.uuidString,
                content: content,
                reasoning: reasoning,
                usage: usage,
                finishReason: finishReason
            ),
            call: call
        )
    }

    func responseFailed(message: String, isCancellation: Bool, in call: ChatTraceCall) {
        record(ResponseFailedPayload(message: message, isCancellation: isCancellation), call: call)
    }

    // MARK: - Tools

    func toolCall(callID: String, name: String, argumentsJSON: String?, in call: ChatTraceCall) {
        record(
            ToolCallPayload(
                callID: callID,
                name: name,
                arguments: argumentsJSON.flatMap { try? TraceJSON.decode($0) }
            ),
            call: call
        )
    }

    func toolResult(
        callID: String,
        name: String?,
        output: String,
        isError: Bool,
        in call: ChatTraceCall
    ) {
        record(
            ToolResultPayload(callID: callID, name: name, output: output, isError: isError),
            call: call
        )
    }

    func toolConsent(callID: String, name: String?, decision: String, in call: ChatTraceCall) {
        record(ToolConsentPayload(callID: callID, name: name, decision: decision), call: call)
    }

    // MARK: - Maintenance

    func prune(retaining window: TraceRetentionWindow) {
        queue.prune(retaining: window)
    }

    /// Waits for queued events to reach the store. For shutdown, not for the
    /// recording path.
    func drain() async {
        await queue.drain()
    }

    // MARK: - Internals

    /// One trace per chat session. Derived rather than allocated so a session
    /// reopened in a later launch keeps appending to the trace it already has.
    private static func traceID(for sessionID: UUID) -> String {
        sessionID.uuidString
    }

    private func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        call: ChatTraceCall
    ) {
        queue.record(payload, traceID: Self.traceID(for: call.sessionID), scope: call.scope())
    }

    private func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        turn: ChatTraceTurn,
        modelID: String? = nil
    ) {
        queue.record(
            payload,
            traceID: Self.traceID(for: turn.sessionID),
            scope: turn.scope(modelID: modelID)
        )
    }
}
