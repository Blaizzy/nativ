import NativServerKit

/// Coalesces server deltas before handing them to the main actor so transcript
/// rendering cannot backpressure the network stream one token at a time.
actor ChatStreamEventRelay {
    typealias Delivery = @MainActor @Sendable (MLXChatStreamDelta) -> Void

    private let deliveryInterval: Duration
    private let delivery: Delivery

    private var pendingContent = ""
    private var pendingReasoning = ""
    private var pendingDecodeTokensPerSecond: Double?
    private var pendingGeneratedTokens: Int?
    private var deliveryTask: Task<Void, Never>?
    private var acceptsEvents = true

    init(
        deliveryInterval: Duration = ChatStreamingRenderPolicy.flushInterval,
        delivery: @escaping Delivery
    ) {
        self.deliveryInterval = deliveryInterval
        self.delivery = delivery
    }

    func submit(_ event: MLXChatStreamDelta) {
        guard acceptsEvents else {
            return
        }

        pendingContent.append(contentsOf: event.content ?? "")
        pendingReasoning.append(contentsOf: event.reasoningContent ?? "")
        pendingDecodeTokensPerSecond =
            event.decodeTokensPerSecond ?? pendingDecodeTokensPerSecond
        pendingGeneratedTokens = event.generatedTokens ?? pendingGeneratedTokens
        scheduleDeliveryIfNeeded()
    }

    func finish() async {
        acceptsEvents = false
        await stopScheduledDelivery()
        if let event = takePendingEvent() {
            await delivery(event)
        }
    }

    func cancel() async {
        acceptsEvents = false
        clearPending()
        await stopScheduledDelivery()
    }

    private func scheduleDeliveryIfNeeded() {
        guard acceptsEvents, deliveryTask == nil, hasPendingEvent else {
            return
        }

        let interval = deliveryInterval
        deliveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.deliverScheduledEvent()
        }
    }

    private func deliverScheduledEvent() async {
        guard acceptsEvents, let event = takePendingEvent() else {
            deliveryTask = nil
            return
        }

        await delivery(event)
        deliveryTask = nil
        scheduleDeliveryIfNeeded()
    }

    private func stopScheduledDelivery() async {
        let task = deliveryTask
        task?.cancel()
        await task?.value
        deliveryTask = nil
    }

    private var hasPendingEvent: Bool {
        !pendingContent.isEmpty
            || !pendingReasoning.isEmpty
            || pendingDecodeTokensPerSecond != nil
            || pendingGeneratedTokens != nil
    }

    private func takePendingEvent() -> MLXChatStreamDelta? {
        guard hasPendingEvent else {
            return nil
        }

        let event = MLXChatStreamDelta(
            content: pendingContent.isEmpty ? nil : pendingContent,
            reasoningContent: pendingReasoning.isEmpty ? nil : pendingReasoning,
            decodeTokensPerSecond: pendingDecodeTokensPerSecond,
            generatedTokens: pendingGeneratedTokens
        )
        clearPending()
        return event
    }

    private func clearPending() {
        pendingContent = ""
        pendingReasoning = ""
        pendingDecodeTokensPerSecond = nil
        pendingGeneratedTokens = nil
    }
}
