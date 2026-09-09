import NativServerKit
import XCTest

@MainActor
final class ChatStreamEventRelayTests: XCTestCase {
    func testFinishCoalescesBurstAndPreservesLatestMetrics() async {
        var deliveries: [MLXChatStreamDelta] = []
        let relay = ChatStreamEventRelay(
            deliveryInterval: .seconds(60),
            delivery: { deliveries.append($0) }
        )

        for index in 1...200 {
            await relay.submit(
                MLXChatStreamDelta(
                    content: "x",
                    reasoningContent: index.isMultiple(of: 20) ? "r" : nil,
                    decodeTokensPerSecond: Double(index),
                    generatedTokens: index
                )
            )
        }
        await relay.finish()

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].content, String(repeating: "x", count: 200))
        XCTAssertEqual(deliveries[0].reasoningContent, String(repeating: "r", count: 10))
        XCTAssertEqual(deliveries[0].decodeTokensPerSecond, 200)
        XCTAssertEqual(deliveries[0].generatedTokens, 200)
    }

    func testScheduledDeliveryPublishesPendingOutput() async {
        var deliveries: [MLXChatStreamDelta] = []
        let delivered = expectation(description: "Delivered pending output")
        let relay = ChatStreamEventRelay(
            deliveryInterval: .zero,
            delivery: {
                deliveries.append($0)
                delivered.fulfill()
            }
        )

        await relay.submit(
            MLXChatStreamDelta(
                content: "complete output",
                decodeTokensPerSecond: 210,
                generatedTokens: 26
            )
        )
        await fulfillment(of: [delivered], timeout: 1)
        await relay.finish()

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].content, "complete output")
        XCTAssertEqual(deliveries[0].decodeTokensPerSecond, 210)
        XCTAssertEqual(deliveries[0].generatedTokens, 26)
    }

    func testCancelDropsPendingOutput() async {
        var deliveries: [MLXChatStreamDelta] = []
        let relay = ChatStreamEventRelay(
            deliveryInterval: .seconds(60),
            delivery: { deliveries.append($0) }
        )

        await relay.submit(MLXChatStreamDelta(content: "stale"))
        await relay.cancel()
        await relay.submit(MLXChatStreamDelta(content: "too late"))

        XCTAssertTrue(deliveries.isEmpty)
    }
}
