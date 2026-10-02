import AppKit
import NativServerKit
import QuartzCore
import Synchronization

@MainActor
final class ChatStreamEventRelay {
    typealias Delivery = @MainActor @Sendable (MLXChatStreamDelta) -> Void

    private let deliveryInterval: Duration
    private let delivery: Delivery
    private nonisolated let pending = Mutex(PendingEvent())
    private var displayLink: CADisplayLink?
    private var lastDelivery: ContinuousClock.Instant?

    init(
        deliveryInterval: Duration = ChatStreamingRenderPolicy.flushInterval,
        delivery: @escaping Delivery
    ) {
        self.deliveryInterval = deliveryInterval
        self.delivery = delivery

        let target = DisplayLinkTarget(relay: self)
        displayLink = NSScreen.main?.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        displayLink?.preferredFrameRateRange = .init(minimum: 60, maximum: 60, preferred: 60)
        displayLink?.add(to: .main, forMode: .common)
    }

    isolated deinit {
        displayLink?.invalidate()
    }

    nonisolated func submit(_ event: MLXChatStreamDelta) {
        pending.withLock { state in
            guard state.acceptsEvents else { return }
            state.content.append(contentsOf: event.content ?? "")
            state.reasoning.append(contentsOf: event.reasoningContent ?? "")
            state.decodeTokensPerSecond = event.decodeTokensPerSecond ?? state.decodeTokensPerSecond
            state.generatedTokens = event.generatedTokens ?? state.generatedTokens
        }
    }

    func finish() {
        stopDisplayLink()
        let event = pending.withLock { state in
            state.acceptsEvents = false
            return state.take()
        }
        if let event {
            delivery(event)
        }
    }

    func cancel() {
        stopDisplayLink()
        pending.withLock { $0 = PendingEvent(acceptsEvents: false) }
    }

    private func flushIfReady() {
        if let lastDelivery, lastDelivery.duration(to: .now) < deliveryInterval {
            return
        }
        guard let event = pending.withLock({ $0.take() }) else { return }

        lastDelivery = .now
        delivery(event)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private struct PendingEvent {
        var acceptsEvents = true
        var content = ""
        var reasoning = ""
        var decodeTokensPerSecond: Double?
        var generatedTokens: Int?

        mutating func take() -> MLXChatStreamDelta? {
            guard !content.isEmpty || !reasoning.isEmpty || decodeTokensPerSecond != nil || generatedTokens != nil
            else { return nil }

            let event = MLXChatStreamDelta(
                content: content.isEmpty ? nil : content,
                reasoningContent: reasoning.isEmpty ? nil : reasoning,
                decodeTokensPerSecond: decodeTokensPerSecond,
                generatedTokens: generatedTokens
            )
            self = PendingEvent(acceptsEvents: acceptsEvents)
            return event
        }
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var relay: ChatStreamEventRelay?

        init(relay: ChatStreamEventRelay) {
            self.relay = relay
        }

        @objc func tick(_ sender: CADisplayLink) {
            relay?.flushIfReady()
        }
    }
}
