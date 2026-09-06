import Foundation
import NativTrace

/// Turns chat activity into trace events.
///
/// Recording must never slow a chat down and must never reorder it. Callers
/// hand work over synchronously and return immediately; a single consumer task
/// drains the queue in order.
///
/// Firing a detached `Task` per event would satisfy the first requirement and
/// break the second — independent tasks reach an actor in whatever order the
/// scheduler picks, so a tool result could be written before the call it
/// answers. One stream with one consumer is what keeps sequence numbers
/// matching what actually happened.
@MainActor
final class ChatTraceProducer {
    private enum Job {
        case record(kind: TraceEventKind, payload: TraceJSON, traceID: String, scope: TraceScope)
        case delta(content: String?, reasoning: String?, traceID: String, scope: TraceScope)
        case discardPartial(traceID: String, scope: TraceScope)
        case prune(TraceRetentionWindow)
    }

    private let continuation: AsyncStream<Job>.Continuation
    private let pump: Task<Void, Never>
    private var traceIDBySession: [UUID: String] = [:]

    init(recorder: TraceRecorder) {
        let (stream, continuation) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        pump = Task {
            for await job in stream {
                switch job {
                case .record(let kind, let payload, let traceID, let scope):
                    await recorder.record(kind: kind, json: payload, traceID: traceID, scope: scope)
                case .delta(let content, let reasoning, let traceID, let scope):
                    await recorder.appendDelta(
                        content: content, reasoning: reasoning, traceID: traceID, scope: scope
                    )
                case .discardPartial(let traceID, let scope):
                    await recorder.discardPartial(traceID: traceID, scope: scope)
                case .prune(let window):
                    await recorder.prune(retaining: window)
                }
            }
        }
    }

    deinit {
        continuation.finish()
        pump.cancel()
    }

    /// One trace per chat session, stable for the lifetime of the process.
    func traceID(for sessionID: UUID) -> String {
        if let existing = traceIDBySession[sessionID] { return existing }
        let traceID = sessionID.uuidString
        traceIDBySession[sessionID] = traceID
        return traceID
    }

    // MARK: - Session and turn

    func sessionStarted(sessionID: UUID, title: String?, modelID: String?) {
        enqueue(
            SessionStartedPayload(title: title, modelID: modelID),
            sessionID: sessionID,
            scope: TraceScope(sessionID: sessionID.uuidString, modelID: modelID)
        )
    }

    func turnStarted(
        sessionID: UUID,
        turnID: UUID,
        messageID: UUID,
        text: String,
        attachmentSummaries: [String],
        modelID: String?
    ) {
        enqueue(
            TurnStartedPayload(
                messageID: messageID.uuidString,
                text: text,
                attachmentSummaries: attachmentSummaries.isEmpty ? nil : attachmentSummaries
            ),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, modelID: modelID)
        )
    }

    func turnEnded(sessionID: UUID, turnID: UUID, status: String, roundCount: Int) {
        enqueue(
            TurnEndedPayload(status: status, roundCount: roundCount),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID)
        )
    }

    // MARK: - Calls

    func requestComposed(
        _ exposure: RequestComposedPayload,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        round: Int,
        modelID: String?
    ) {
        enqueue(
            exposure,
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, requestID: requestID, round: round, modelID: modelID)
        )
    }

    func delta(
        content: String?,
        reasoning: String?,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID
    ) {
        continuation.yield(.delta(
            content: content,
            reasoning: reasoning,
            traceID: traceID(for: sessionID),
            scope: scope(sessionID, turnID: turnID, requestID: requestID)
        ))
    }

    func responseCompleted(
        messageID: UUID,
        content: String,
        reasoning: String?,
        usage: TraceUsage?,
        finishReason: String?,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID,
        modelID: String?
    ) {
        let scope = scope(sessionID, turnID: turnID, requestID: requestID, modelID: modelID)
        continuation.yield(.discardPartial(traceID: traceID(for: sessionID), scope: scope))
        enqueue(
            ResponseCompletedPayload(
                messageID: messageID.uuidString,
                content: content,
                reasoning: reasoning,
                usage: usage,
                finishReason: finishReason
            ),
            sessionID: sessionID,
            scope: scope
        )
    }

    func responseFailed(
        message: String,
        isCancellation: Bool,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID
    ) {
        enqueue(
            ResponseFailedPayload(message: message, isCancellation: isCancellation),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, requestID: requestID)
        )
    }

    // MARK: - Tools

    func toolCall(
        callID: String,
        name: String,
        argumentsJSON: String?,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID
    ) {
        enqueue(
            ToolCallPayload(
                callID: callID,
                name: name,
                arguments: argumentsJSON.flatMap { try? TraceJSON.decode($0) }
            ),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, requestID: requestID)
        )
    }

    func toolResult(
        callID: String,
        name: String?,
        output: String,
        isError: Bool,
        durationMilliseconds: Int?,
        sessionID: UUID,
        turnID: UUID,
        requestID: UUID
    ) {
        enqueue(
            ToolResultPayload(
                callID: callID,
                name: name,
                output: output,
                isError: isError,
                durationMilliseconds: durationMilliseconds
            ),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, requestID: requestID)
        )
    }

    func modelSwitched(from: String?, to: String, sessionID: UUID, turnID: UUID?) {
        enqueue(
            ModelSwitchedPayload(from: from, to: to),
            sessionID: sessionID,
            scope: scope(sessionID, turnID: turnID, modelID: to)
        )
    }

    // MARK: - Retention

    func prune(retaining window: TraceRetentionWindow) {
        continuation.yield(.prune(window))
    }

    // MARK: - Internals

    private func enqueue<Payload: TracePayloadView & Encodable>(
        _ payload: Payload,
        sessionID: UUID,
        scope: TraceScope
    ) {
        guard let json = try? TraceJSON(encoding: payload) else { return }
        continuation.yield(.record(
            kind: Payload.kind,
            payload: json,
            traceID: traceID(for: sessionID),
            scope: scope
        ))
    }

    private func scope(
        _ sessionID: UUID,
        turnID: UUID? = nil,
        requestID: UUID? = nil,
        round: Int? = nil,
        modelID: String? = nil
    ) -> TraceScope {
        TraceScope(
            sessionID: sessionID.uuidString,
            turnID: turnID?.uuidString,
            requestID: requestID?.uuidString,
            roundIndex: round,
            modelID: modelID
        )
    }
}
