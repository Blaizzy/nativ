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
    /// The trace a chat is currently writing to, and the model it belongs to.
    private struct OpenTrace {
        let traceID: String
        let modelID: String?
    }

    /// Enough of the current turn to replay into a trace that opens mid-turn.
    private struct TurnContext {
        let turn: ChatTraceTurn
        let messageID: UUID
        let text: String
        /// Traces that already hold this prompt. Without it, the trace opened
        /// by `turnStarted` would be replayed into by the very call that is
        /// about to record the prompt itself.
        var recordedIn: Set<String> = []
    }

    private let queue: TraceEventQueue
    private var openTraceBySession: [UUID: OpenTrace] = [:]
    private var turnContextBySession: [UUID: TurnContext] = [:]

    init(recorder: TraceRecorder) {
        queue = TraceEventQueue(recorder: recorder)
    }

    // MARK: - Session and turn

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

    func turnEnded(_ turn: ChatTraceTurn, status: String, roundCount: Int) {
        record(TurnEndedPayload(status: status, roundCount: roundCount), turn: turn)
        turnContextBySession[turn.sessionID] = nil
    }

    // MARK: - Calls

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

    /// Seals open calls and waits for everything queued to reach the store.
    /// For shutdown, not for the recording path.
    func shutDown() async {
        queue.flushAll()
        await queue.drain()
    }

    /// Waits for queued events to reach the store, without sealing.
    func drain() async {
        await queue.drain()
    }

    // MARK: - Internals

    /// The trace a chat's events belong to, opening a new one when the model
    /// changes.
    ///
    /// A chat is not one trace. Every model the server loads to serve a chat
    /// gets its own trace instance, because two models shown two different
    /// system prompts and two different tool sets are two different things to
    /// reason about — folding them into one transcript with a divider in the
    /// middle asks the reader to do the separating.
    ///
    /// Session id stays a column on every event, so a chat can still list all of
    /// its traces in order.
    private func openTrace(session sessionID: UUID, modelID: String?) -> String {
        if let open = openTraceBySession[sessionID], open.modelID == modelID {
            return open.traceID
        }

        let previous = openTraceBySession[sessionID]
        let traceID = "\(sessionID.uuidString)/\(UUID().uuidString.prefix(8))"
        openTraceBySession[sessionID] = OpenTrace(traceID: traceID, modelID: modelID)

        // Every trace opens by saying what it is: a chat starting, or one model
        // taking over from another.
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

        // A trace that opens part way through a turn would otherwise start with
        // an answer and no question. Replaying the prompt keeps each trace
        // readable on its own, which is the point of splitting them.
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

    /// The trace a chat is already writing to.
    ///
    /// Only `sessionStarted`, `turnStarted`, and `requestComposed` may open a
    /// trace. Everything else — deltas, tool rows, completions — belongs to a
    /// call that has already been composed, so a mismatch here means a
    /// straggler, and opening a trace for it would produce a one-event trace
    /// with a replayed prompt and a spurious entry in the model picker.
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
        // turnStarted supplies a model and may open a trace; turnEnded does
        // not and joins whatever is open.
        guard let traceID = modelID == nil
            ? currentTraceID(session: turn.sessionID)
            : openTrace(session: turn.sessionID, modelID: modelID)
        else { return }
        queue.record(payload, traceID: traceID, scope: turn.scope(modelID: modelID))
    }
}
