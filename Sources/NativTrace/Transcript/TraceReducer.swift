import Foundation

/// Folds trace events into renderable items.
///
/// The fold is the only place event semantics live. It is incremental so a live
/// session can append one event at a time, and `items(for:)` replays the same
/// steps for a cold read — feeding events one by one and feeding them in a batch
/// must produce identical output, which is what makes the derived transcript
/// safe to discard and rebuild.
///
/// An event this build does not recognise becomes a `.unknown` item rather than
/// being skipped, so a trace never renders shorter than it is.
public struct TraceReducer: Sendable {
    public private(set) var items: [TraceItem] = []

    private var indexByItemID: [String: Int] = [:]
    private var openAssistantItemID: [TraceCallKey: String] = [:]
    private var toolItemIDByCallID: [String: String] = [:]

    public init() {}

    public static func items(for events: [TraceEvent]) -> [TraceItem] {
        var reducer = TraceReducer()
        for event in events.sorted(by: TraceEvent.ordered) {
            reducer.apply(event)
        }
        return reducer.items
    }

    public mutating func apply(_ event: TraceEvent) {
        switch event.kind {
        case .sessionStarted:
            applySessionStarted(event)
        case .turnStarted:
            applyTurnStarted(event)
        case .turnEnded:
            applyTurnEnded(event)
        case .requestComposed:
            applyRequestComposed(event)
        case .requestSent:
            applyRequestSent(event)
        case .responseDelta:
            applyResponseDelta(event)
        case .responseCompleted:
            applyResponseCompleted(event)
        case .responseFailed:
            applyResponseFailed(event)
        case .toolCall:
            applyToolCall(event)
        case .toolResult:
            applyToolResult(event)
        case .toolConsent:
            applyToolConsent(event)
        case .modelSwitched:
            applyModelSwitched(event)
        default:
            append(event, body: .unknown(kind: event.kind, payload: event.payload))
        }
    }

    // MARK: - Handlers

    private mutating func applySessionStarted(_ event: TraceEvent) {
        let payload = SessionStartedPayload(event: event)
        append(event, body: .lifecycle(TraceLifecycleBody(
            kind: .sessionStarted,
            title: payload?.title ?? "Session started",
            detail: payload?.modelID
        )))
    }

    private mutating func applyTurnStarted(_ event: TraceEvent) {
        guard let payload = TurnStartedPayload(event: event) else {
            return appendUnreadable(event)
        }
        append(event, body: .message(TraceMessageBody(
            role: .user,
            messageID: payload.messageID,
            text: payload.text,
            attachmentSummaries: payload.attachmentSummaries ?? []
        )))
    }

    private mutating func applyTurnEnded(_ event: TraceEvent) {
        guard let payload = TurnEndedPayload(event: event) else {
            return appendUnreadable(event)
        }
        sealOpenAssistants()
        append(event, body: .lifecycle(TraceLifecycleBody(
            kind: .turnEnded,
            title: payload.status,
            detail: payload.roundCount.map { "\($0) round\($0 == 1 ? "" : "s")" }
        )))
    }

    private mutating func applyRequestComposed(_ event: TraceEvent) {
        guard let payload = RequestComposedPayload(event: event) else {
            return appendUnreadable(event)
        }
        append(event, body: .exposure(payload))
    }

    private mutating func applyRequestSent(_ event: TraceEvent) {
        guard let payload = RequestSentPayload(event: event) else {
            return appendUnreadable(event)
        }
        append(event, body: .wireRequest(payload))
    }

    private mutating func applyResponseDelta(_ event: TraceEvent) {
        guard let payload = ResponseDeltaPayload(event: event) else {
            return appendUnreadable(event)
        }

        let key = callKey(for: event)
        if let itemID = openAssistantItemID[key], let index = indexByItemID[itemID] {
            guard case .message(var message) = items[index].body else { return }
            message.text += payload.content ?? ""
            if let reasoning = payload.reasoning {
                message.reasoning = (message.reasoning ?? "") + reasoning
            }
            items[index].body = .message(message)
            return
        }

        let itemID = append(event, body: .message(TraceMessageBody(
            role: .assistant,
            text: payload.content ?? "",
            reasoning: payload.reasoning,
            isStreaming: true
        )))
        openAssistantItemID[key] = itemID
    }

    private mutating func applyResponseCompleted(_ event: TraceEvent) {
        guard let payload = ResponseCompletedPayload(event: event) else {
            return appendUnreadable(event)
        }

        let completed = TraceMessageBody(
            role: .assistant,
            messageID: payload.messageID,
            text: payload.content,
            reasoning: payload.reasoning,
            isStreaming: false,
            usage: payload.usage,
            finishReason: payload.finishReason
        )

        let key = callKey(for: event)
        if let itemID = openAssistantItemID.removeValue(forKey: key),
           let index = indexByItemID[itemID] {
            items[index].body = .message(completed)
            return
        }
        append(event, body: .message(completed))
    }

    private mutating func applyResponseFailed(_ event: TraceEvent) {
        guard let payload = ResponseFailedPayload(event: event) else {
            return appendUnreadable(event)
        }
        sealOpenAssistants()
        append(event, body: .lifecycle(TraceLifecycleBody(
            kind: .failure,
            title: payload.isCancellation == true ? "Cancelled" : "Failed",
            detail: payload.message
        )))
    }

    private mutating func applyToolCall(_ event: TraceEvent) {
        guard let payload = ToolCallPayload(event: event) else {
            return appendUnreadable(event)
        }

        if let itemID = toolItemIDByCallID[payload.callID], let index = indexByItemID[itemID] {
            guard case .tool(var tool) = items[index].body else { return }
            tool.name = payload.name
            tool.origin = payload.origin ?? tool.origin
            tool.originDetail = payload.originDetail ?? tool.originDetail
            tool.arguments = payload.arguments ?? tool.arguments
            if tool.status == .awaitingConsent, tool.consentDecision == "approved" {
                tool.status = .running
            }
            items[index].body = .tool(tool)
            return
        }

        let itemID = append(event, body: .tool(TraceToolBody(
            callID: payload.callID,
            name: payload.name,
            origin: payload.origin,
            originDetail: payload.originDetail,
            arguments: payload.arguments,
            status: .running
        )))
        toolItemIDByCallID[payload.callID] = itemID
    }

    private mutating func applyToolResult(_ event: TraceEvent) {
        guard let payload = ToolResultPayload(event: event) else {
            return appendUnreadable(event)
        }

        guard let itemID = toolItemIDByCallID[payload.callID],
              let index = indexByItemID[itemID],
              case .tool(var tool) = items[index].body
        else {
            append(event, body: .tool(TraceToolBody(
                callID: payload.callID,
                name: payload.name ?? "unknown",
                status: payload.isError == true ? .failed : .completed,
                output: payload.output,
                durationMilliseconds: payload.durationMilliseconds
            )))
            return
        }

        tool.status = payload.isError == true ? .failed : .completed
        tool.output = payload.output
        tool.durationMilliseconds = payload.durationMilliseconds
        if let name = payload.name { tool.name = name }
        items[index].body = .tool(tool)
    }

    private mutating func applyToolConsent(_ event: TraceEvent) {
        guard let payload = ToolConsentPayload(event: event) else {
            return appendUnreadable(event)
        }

        if let itemID = toolItemIDByCallID[payload.callID],
           let index = indexByItemID[itemID],
           case .tool(var tool) = items[index].body {
            tool.consentDecision = payload.decision
            tool.status = status(afterConsent: payload.decision, current: tool.status)
            items[index].body = .tool(tool)
            return
        }

        let itemID = append(event, body: .tool(TraceToolBody(
            callID: payload.callID,
            name: payload.name ?? "unknown",
            status: status(afterConsent: payload.decision, current: .awaitingConsent),
            consentDecision: payload.decision
        )))
        toolItemIDByCallID[payload.callID] = itemID
    }

    private mutating func applyModelSwitched(_ event: TraceEvent) {
        guard let payload = ModelSwitchedPayload(event: event) else {
            return appendUnreadable(event)
        }
        append(event, body: .lifecycle(TraceLifecycleBody(
            kind: .modelSwitched,
            title: payload.to,
            detail: payload.from
        )))
    }

    // MARK: - Helpers

    private func status(
        afterConsent decision: String,
        current: TraceToolBody.Status
    ) -> TraceToolBody.Status {
        switch decision {
        case "approved": .running
        case "denied": .denied
        case "cancelled": .denied
        case "requested": .awaitingConsent
        default: current
        }
    }

    private func callKey(for event: TraceEvent) -> TraceCallKey {
        TraceCallKey(traceID: event.traceID, scope: event.scope)
    }

    /// Marks every still-streaming assistant message as finished.
    ///
    /// A turn-ending event has no requestID, so it cannot name the call whose
    /// message is open — matching on the key it derives never succeeds and
    /// leaves a finished transcript rendering a live placeholder.
    private mutating func sealOpenAssistants() {
        for (key, itemID) in openAssistantItemID {
            openAssistantItemID.removeValue(forKey: key)
            guard let index = indexByItemID[itemID],
                  case .message(var message) = items[index].body
            else { continue }
            message.isStreaming = false
            items[index].body = .message(message)
        }
    }

    @discardableResult
    private mutating func append(_ event: TraceEvent, body: TraceItem.Body) -> String {
        let item = TraceItem(id: event.id, timestamp: event.timestamp, scope: event.scope, body: body)
        indexByItemID[item.id] = items.count
        items.append(item)
        return item.id
    }

    /// A payload of a known kind that could not be read — a corrupt row, or a
    /// shape a future build changed incompatibly. Surfaced rather than dropped.
    private mutating func appendUnreadable(_ event: TraceEvent) {
        append(event, body: .unknown(kind: event.kind, payload: event.payload))
    }
}
