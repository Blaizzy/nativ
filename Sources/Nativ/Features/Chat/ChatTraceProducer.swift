import Foundation
import NativTrace

@MainActor
final class ChatTraceProducer {
    private struct OpenTrace {
        let traceID: String
        let modelID: String?
    }

    private struct TurnContext {
        let turn: ChatTraceTurn
        let messageID: UUID
        let text: String
        var recordedIn: Set<String> = []
    }

    private let queue: TraceEventQueue
    private var openTraceBySession: [UUID: OpenTrace] = [:]
    private var turnContextBySession: [UUID: TurnContext] = [:]

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
        let traceID = openTrace(session: turn.sessionID, modelID: modelID)
        turnContextBySession[turn.sessionID] = TurnContext(
            turn: turn, messageID: messageID, text: text, recordedIn: [traceID]
        )
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

    func turnEnded(_ turn: ChatTraceTurn, status: TraceTurnStatus, roundCount: Int) {
        record(TurnEndedPayload(status: status, roundCount: roundCount), turn: turn)
        turnContextBySession[turn.sessionID] = nil
    }

    func requestComposed(_ exposure: RequestComposedPayload, in call: ChatTraceCall) {
        queue.record(
            exposure,
            traceID: openTrace(session: call.sessionID, modelID: call.modelID),
            scope: call.scope()
        )
    }

    func delta(content: String?, reasoning: String?, in call: ChatTraceCall) {
        guard let traceID = currentTraceID(session: call.sessionID) else { return }
        queue.delta(
            content: content,
            reasoning: reasoning,
            traceID: traceID,
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
        if let traceID = currentTraceID(session: call.sessionID) {
            queue.discardPartial(traceID: traceID, scope: call.scope())
        }
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

    private func openTrace(session sessionID: UUID, modelID: String?) -> String {
        if let open = openTraceBySession[sessionID], open.modelID == modelID {
            return open.traceID
        }

        let previous = openTraceBySession[sessionID]
        let traceID = "\(sessionID.uuidString)/\(UUID().uuidString.prefix(8))"
        openTraceBySession[sessionID] = OpenTrace(traceID: traceID, modelID: modelID)

        if let previous {
            queue.record(
                ModelSwitchedPayload(from: previous.modelID, to: modelID ?? "unknown"),
                traceID: traceID,
                scope: TraceScope(sessionID: sessionID.uuidString, modelID: modelID)
            )
        } else {
            queue.record(
                SessionStartedPayload(title: nil, modelID: modelID),
                traceID: traceID,
                scope: TraceScope(sessionID: sessionID.uuidString, modelID: modelID)
            )
        }

        if var context = turnContextBySession[sessionID], !context.recordedIn.contains(traceID) {
            context.recordedIn.insert(traceID)
            turnContextBySession[sessionID] = context
            queue.record(
                TurnStartedPayload(messageID: context.messageID.uuidString, text: context.text),
                traceID: traceID,
                scope: context.turn.scope(modelID: modelID)
            )
        }
        return traceID
    }

    private func currentTraceID(session sessionID: UUID) -> String? {
        openTraceBySession[sessionID]?.traceID
    }

    private func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        call: ChatTraceCall
    ) {
        guard let traceID = currentTraceID(session: call.sessionID) else { return }
        queue.record(payload, traceID: traceID, scope: call.scope())
    }

    private func record<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        turn: ChatTraceTurn,
        modelID: String? = nil
    ) {
        guard let traceID = modelID == nil
            ? currentTraceID(session: turn.sessionID)
            : openTrace(session: turn.sessionID, modelID: modelID)
        else { return }
        queue.record(payload, traceID: traceID, scope: turn.scope(modelID: modelID))
    }
}
