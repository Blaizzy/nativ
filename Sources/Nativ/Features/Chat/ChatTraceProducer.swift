import Foundation
import NativTrace

@MainActor
final class ChatTraceProducer {
    private let queue: TraceEventQueue
    private var observedSessions = Set<UUID>()
    private var modelIDBySession: [UUID: String] = [:]

    init(recorder: TraceRecorder) {
        queue = TraceEventQueue(recorder: recorder)
    }

    func turnStarted(
        _ turn: ChatTraceTurn,
        messageID: UUID,
        text: String,
        attachmentSummaries: [String] = [],
        modelID: String?
    ) {
        let traceID = traceID(for: turn.sessionID, modelID: modelID)
        queue.record(
            TurnStartedPayload(
                messageID: messageID.uuidString,
                text: text,
                attachmentSummaries: attachmentSummaries.isEmpty ? nil : attachmentSummaries
            ),
            traceID: traceID,
            scope: turn.scope(modelID: modelID)
        )
    }

    func turnEnded(_ turn: ChatTraceTurn, status: TraceTurnStatus, roundCount: Int) {
        queue.record(
            TurnEndedPayload(status: status, roundCount: roundCount),
            traceID: turn.sessionID.uuidString,
            scope: turn.scope()
        )
    }

    func requestComposed(_ exposure: RequestComposedPayload, in call: ChatTraceCall) {
        queue.record(
            exposure,
            traceID: traceID(for: call.sessionID, modelID: call.modelID),
            scope: call.scope()
        )
    }

    func delta(content: String?, reasoning: String?, in call: ChatTraceCall) {
        queue.delta(
            content: content,
            reasoning: reasoning,
            traceID: call.sessionID.uuidString,
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
        queue.discardPartial(traceID: call.sessionID.uuidString, scope: call.scope())
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

    func toolConsent(
        callID: String,
        name: String?,
        decision: TraceConsentDecision,
        in call: ChatTraceCall
    ) {
        record(ToolConsentPayload(callID: callID, name: name, decision: decision), call: call)
    }

    func prune(retaining window: TraceRetentionWindow) {
        queue.prune(retaining: window)
    }

    func shutDown() async {
        queue.flushAll()
        await queue.drain()
    }

    func drain() async {
        await queue.drain()
    }

    private func traceID(for sessionID: UUID, modelID: String?) -> String {
        if !observedSessions.insert(sessionID).inserted,
           modelIDBySession[sessionID] != modelID {
            queue.record(
                ModelSwitchedPayload(from: modelIDBySession[sessionID], to: modelID ?? "unknown"),
                traceID: sessionID.uuidString,
                scope: TraceScope(sessionID: sessionID.uuidString, modelID: modelID)
            )
        }
        if let modelID {
            modelIDBySession[sessionID] = modelID
        } else {
            modelIDBySession.removeValue(forKey: sessionID)
        }
        return sessionID.uuidString
    }

    private func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        call: ChatTraceCall
    ) {
        queue.record(
            payload,
            traceID: traceID(for: call.sessionID, modelID: call.modelID),
            scope: call.scope()
        )
    }
}
