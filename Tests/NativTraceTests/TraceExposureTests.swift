import XCTest
import NativTrace

final class TraceExposureTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Resolution

    func testMessageReferenceResolvesAgainstTheTrace() throws {
        let body = "what is the capital of france"
        let items = TraceReducer.items(for: [
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .turnStarted,
                scope: TraceScope(turnID: "u1"),
                payload: try TurnStartedPayload(messageID: "m1", text: body).makePayload()
            )
        ])

        let exposure = TraceExposureIndex(items: items).resolve(
            RequestComposedPayload(messages: [
                TraceMessageRef(
                    role: .user, messageID: "m1",
                    contentHash: TraceHash.content(body)
                )
            ])
        )

        let message = try XCTUnwrap(exposure.messages.first)
        XCTAssertEqual(message.text, body)
        XCTAssertTrue(message.isVerified)
    }

    func testEditedMessageResolvesButIsNotVerified() throws {
        let items = TraceReducer.items(for: [
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .turnStarted,
                scope: TraceScope(turnID: "u1"),
                payload: try TurnStartedPayload(messageID: "m1", text: "edited text").makePayload()
            )
        ])

        let exposure = TraceExposureIndex(items: items).resolve(
            RequestComposedPayload(messages: [
                TraceMessageRef(
                    role: .user, messageID: "m1",
                    contentHash: TraceHash.content("original text")
                )
            ])
        )

        let message = try XCTUnwrap(exposure.messages.first)
        XCTAssertEqual(message.text, "edited text")
        XCTAssertFalse(message.isVerified, "a body that no longer hashes to what was sent is not what the model saw")
    }

    func testUnresolvableMessageIsReportedRatherThanInvented() {
        let exposure = TraceExposureIndex(items: []).resolve(
            RequestComposedPayload(messages: [
                TraceMessageRef(role: .user, messageID: "gone", contentHash: "abc")
            ])
        )

        XCTAssertTrue(exposure.messages.first?.isMissing == true)
        XCTAssertNil(exposure.messages.first?.text)
    }

    func testInlinedBodyIsUsedWhenTheTraceCannotSupplyOne() throws {
        let body = "imported from elsewhere"
        let exposure = TraceExposureIndex(items: []).resolve(
            RequestComposedPayload(messages: [
                TraceMessageRef(
                    role: .user, messageID: "m1",
                    contentHash: TraceHash.content(body),
                    inlineBody: body
                )
            ])
        )

        XCTAssertEqual(exposure.messages.first?.text, body)
        XCTAssertTrue(exposure.messages.first?.isVerified == true)
    }

    func testToolOutputResolvesAsAMessageBody() throws {
        let output = "2 results"
        let items = TraceReducer.items(for: [
            TraceEvent(
                traceID: "t1", seq: 0, timestamp: base, kind: .toolCall,
                payload: try ToolCallPayload(callID: "c1", name: "web_search").makePayload()
            ),
            TraceEvent(
                traceID: "t1", seq: 1, timestamp: base, kind: .toolResult,
                payload: try ToolResultPayload(callID: "c1", output: output).makePayload()
            ),
        ])

        let exposure = TraceExposureIndex(items: items).resolve(
            RequestComposedPayload(messages: [
                TraceMessageRef(
                    role: .tool, messageID: "c1",
                    contentHash: TraceHash.content(output)
                )
            ])
        )

        XCTAssertEqual(exposure.messages.first?.text, output)
        XCTAssertTrue(exposure.messages.first?.isVerified == true)
    }

    // MARK: - Diff

    func testFirstCallHasNoDiff() {
        let diff = TraceExposureDiff.between(nil, and: RequestComposedPayload())

        XCTAssertTrue(diff.isEmpty)
    }

    func testWithheldToolsShowAsRemoved() {
        let withTools = RequestComposedPayload(
            tools: [ToolDescriptor(name: "web_search", origin: .builtIn)],
            advertisesTools: true
        )
        let withoutTools = RequestComposedPayload(tools: [], advertisesTools: false)

        let diff = TraceExposureDiff.between(withTools, and: withoutTools)

        XCTAssertEqual(diff.removedTools.map(\.name), ["web_search"])
        XCTAssertTrue(diff.addedTools.isEmpty)
    }

    func testConnectedServerShowsItsToolsAsAdded() {
        let before = RequestComposedPayload(tools: [ToolDescriptor(name: "web_search", origin: .builtIn)])
        let after = RequestComposedPayload(tools: [
            ToolDescriptor(name: "web_search", origin: .builtIn),
            ToolDescriptor(name: "list_issues", origin: .mcp, originDetail: "github"),
        ])

        let diff = TraceExposureDiff.between(before, and: after)

        XCTAssertEqual(diff.addedTools.map(\.name), ["list_issues"])
    }

    func testSameNameDifferentSchemaCountsAsRedefined() {
        let before = RequestComposedPayload(tools: [
            ToolDescriptor(name: "search", origin: .mcp, originDetail: "a", parameters: ["type": "object"])
        ])
        let after = RequestComposedPayload(tools: [
            ToolDescriptor(name: "search", origin: .mcp, originDetail: "a", parameters: ["type": "string"])
        ])

        let diff = TraceExposureDiff.between(before, and: after)

        XCTAssertEqual(diff.redefinedTools.map(\.name), ["search"])
        XCTAssertTrue(diff.addedTools.isEmpty)
        XCTAssertTrue(diff.removedTools.isEmpty)
    }

    func testReorderingSectionsIsNotAnEdit() {
        let a = PromptSection(origin: .userSystemPrompt, label: "System", body: "one")
        let b = PromptSection(origin: .skill, label: "Footnotes", body: "two")

        let diff = TraceExposureDiff.between(
            RequestComposedPayload(systemSections: [a, b]),
            and: RequestComposedPayload(systemSections: [b, a])
        )

        XCTAssertTrue(diff.isEmpty)
    }

    func testEditedSectionBodyIsDetected() {
        let diff = TraceExposureDiff.between(
            RequestComposedPayload(systemSections: [
                PromptSection(origin: .skill, label: "Footnotes", body: "old")
            ]),
            and: RequestComposedPayload(systemSections: [
                PromptSection(origin: .skill, label: "Footnotes", body: "new")
            ])
        )

        XCTAssertEqual(diff.editedSections.map(\.label), ["Footnotes"])
    }
}
