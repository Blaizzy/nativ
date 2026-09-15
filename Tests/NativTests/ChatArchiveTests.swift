import Foundation
import NativServerKit
import XCTest

final class ChatArchiveTests: XCTestCase {
    func testArchiveRoundTripWithPersonalizationExplicitlyIncluded() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var session = makeSession(date: date)
        session.personalizationSnapshot = "User profile:\nPreferred name: Alex"
        let archive = ChatArchive(
            chat: session,
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: "Be concise.",
            includePersonalization: true,
            exportedAt: date
        )

        let data = try ChatArchiveCodec.encode(archive)
        let decoded = try ChatArchiveCodec.decode(data)

        XCTAssertEqual(decoded, archive)
        XCTAssertEqual(decoded.chat.personalizationSnapshot, session.personalizationSnapshot)
        let imported = try ChatArchiveCodec.importedSession(from: decoded)
        XCTAssertEqual(imported.personalizationSnapshot, session.personalizationSnapshot)
    }

    func testExportExcludesPersonalizationByDefaultWithoutChangingTheChat() throws {
        var session = makeSession()
        session.personalizationSnapshot = "User profile:\nPreferred name: PrivateExportMarker\nOccupation: PrivateOccupationMarker"
        let original = session
        let archive = ChatArchive(
            chat: session,
            modelRepositoryID: "test/model",
            systemPrompt: "Be concise."
        )
        let data = try ChatArchiveCodec.encode(archive)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let conversation = try XCTUnwrap(object["chat"] as? [String: Any])

        XCTAssertNil(conversation["personalizationSnapshot"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PrivateExportMarker"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PrivateOccupationMarker"))
        XCTAssertEqual(archive.chat.messages, original.messages)
        XCTAssertEqual(archive.systemPrompt, "Be concise.")
        XCTAssertEqual(session, original)

        let localCopy = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(localCopy.personalizationSnapshot, original.personalizationSnapshot)
        let imported = try ChatArchiveCodec.importedSession(from: ChatArchiveCodec.decode(data))
        XCTAssertEqual(imported.personalizationSnapshot, "")
    }

    func testExportChoiceIncludesOrExcludesOnlyPersonalization() throws {
        var session = makeSession()
        session.personalizationSnapshot = "User profile:\nPreferred name: Alex"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var exportedObjects: [[String: Any]] = []
        for includePersonalization in [true, false] {
            let archive = ChatArchive(
                chat: session,
                modelRepositoryID: "test/model",
                systemPrompt: "Be concise.",
                includePersonalization: includePersonalization,
                exportedAt: date
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: ChatArchiveCodec.encode(archive)) as? [String: Any])
            var conversation = try XCTUnwrap(object["chat"] as? [String: Any])
            XCTAssertEqual(conversation["personalizationSnapshot"] as? String,
                           includePersonalization ? session.personalizationSnapshot : nil)
            conversation.removeValue(forKey: "personalizationSnapshot")
            object["chat"] = conversation
            exportedObjects.append(object)
        }
        XCTAssertTrue(NSDictionary(dictionary: exportedObjects[0]).isEqual(to: exportedObjects[1]))
    }

    func testOlderPersonalizedArchiveImportsButReexportDefaultsToExcludingProfile() throws {
        let archive = ChatArchive(chat: makeSession(), modelRepositoryID: "test/model", systemPrompt: "")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ChatArchiveCodec.encode(archive)) as? [String: Any])
        var conversation = try XCTUnwrap(object["chat"] as? [String: Any])
        let snapshot = "User profile:\nPreferred name: LegacyPrivateMarker"
        conversation["personalizationSnapshot"] = snapshot
        object["chat"] = conversation

        let decoded = try ChatArchiveCodec.decode(JSONSerialization.data(withJSONObject: object))
        let imported = try ChatArchiveCodec.importedSession(from: decoded)
        XCTAssertEqual(imported.personalizationSnapshot, snapshot)
        let reexport = ChatArchive(chat: imported, modelRepositoryID: decoded.modelRepositoryID,
                                   systemPrompt: decoded.systemPrompt)
        XCTAssertNil(reexport.chat.personalizationSnapshot)
        XCTAssertFalse(String(decoding: try ChatArchiveCodec.encode(reexport), as: UTF8.self)
            .contains("LegacyPrivateMarker"))
    }

    func testImportedEmptyChatWithoutProfileDoesNotCaptureRecipientsPersonalization() throws {
        var session = makeSession()
        session.messages = []
        session.personalizationSnapshot = "User profile:\nPreferred name: OriginalUser"
        let archive = ChatArchive(chat: session, modelRepositoryID: "test/model", systemPrompt: "")
        var imported = try ChatArchiveCodec.importedSession(from: archive)
        var recipient = NativPersonalization()
        recipient.profile.preferredName = "Recipient"
        imported.capturePersonalization(recipient)
        XCTAssertEqual(imported.personalizationSnapshot, "")
    }

    func testImportAssignsNewLocalIDsAndPreservesToolCallLinks() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = makeSession(date: date, isStreaming: true)
        let archive = ChatArchive(
            chat: source,
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )

        let imported = try ChatArchiveCodec.importedSession(from: archive, now: date)

        XCTAssertNotEqual(imported.id, source.id)
        XCTAssertEqual(imported.messages.count, source.messages.count)
        XCTAssertNotEqual(imported.messages[0].id, source.messages[0].id)
        XCTAssertNotEqual(
            imported.messages[0].imageAttachments[0].id,
            source.messages[0].imageAttachments[0].id
        )
        XCTAssertEqual(imported.messages[1].toolCalls, source.messages[1].toolCalls)
        XCTAssertEqual(imported.messages[2].toolCallID, source.messages[2].toolCallID)
        XCTAssertEqual(imported.messages[2].toolStatus, .cancelled)
        XCTAssertFalse(imported.messages[2].isStreaming)
        XCTAssertEqual(imported.importedModelRepositoryID, archive.modelRepositoryID)
        XCTAssertEqual(imported.importedSystemPrompt, archive.systemPrompt)
    }

    func testDecodeRejectsAnUnsupportedVersion() throws {
        let archive = ChatArchive(
            chat: makeSession(),
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ChatArchiveCodec.encode(archive)) as? [String: Any]
        )
        object["version"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ChatArchiveCodec.decode(data)) { error in
            XCTAssertEqual(error as? ChatArchiveError, .unsupportedVersion(2))
        }
    }

    func testDecodeRejectsAnInvalidFormat() throws {
        let archive = ChatArchive(
            chat: makeSession(),
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ChatArchiveCodec.encode(archive)) as? [String: Any]
        )
        object["format"] = "some-other-format"
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ChatArchiveCodec.decode(data)) { error in
            XCTAssertEqual(error as? ChatArchiveError, .invalidFormat)
        }
    }

    func testDecodeRejectsInvalidAttachmentData() throws {
        let archive = ChatArchive(
            chat: makeSession(attachmentData: "not base64"),
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )

        XCTAssertThrowsError(try ChatArchiveCodec.decode(ChatArchiveCodec.encode(archive))) { error in
            XCTAssertEqual(
                error as? ChatArchiveError,
                .invalidAttachment("notes.txt")
            )
        }
    }

    func testContinuationAvailability() {
        let archive = ChatArchive(
            chat: makeSession(),
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )
        let installedModel = LocalModel(
            repoID: archive.modelRepositoryID,
            snapshotURL: nil,
            modifiedAt: nil,
            sizeBytes: nil,
            parameterCount: nil,
            quantizationBits: nil,
            quantizationGroupSize: nil,
            contextSize: 4_096,
            provider: nil,
            capabilities: [.text],
            drafterKind: nil,
            hiddenSize: nil
        )

        XCTAssertEqual(
            ChatArchiveCodec.continuationAvailability(
                for: archive,
                installedModels: [],
                currentModelID: nil
            ),
            .modelMissing
        )
        XCTAssertEqual(
            ChatArchiveCodec.continuationAvailability(
                for: archive,
                installedModels: [installedModel],
                currentModelID: "another-model"
            ),
            .ready(requiresModelSwitch: true)
        )
        XCTAssertEqual(
            ChatArchiveCodec.continuationAvailability(
                for: archive,
                installedModels: [installedModel],
                currentModelID: archive.modelRepositoryID,
                promptTokenCount: 4_097
            ),
            .contextExceeded(tokenCount: 4_097, contextWindow: 4_096)
        )
    }

    func testPromptTokenCountUsesTheLatestAssistantMetrics() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var session = makeSession(date: date)
        session.messages.append(
            ChatTranscriptMessage(
                role: .assistant,
                content: "Done",
                createdAt: date,
                responseMetrics: ChatResponseMetrics(totalTokens: 321)
            )
        )
        let archive = ChatArchive(
            chat: session,
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )

        XCTAssertEqual(ChatArchiveCodec.promptTokenCount(in: archive), 321)
    }

    private func makeSession(
        date: Date = .now,
        attachmentData: String = Data("hello".utf8).base64EncodedString(),
        isStreaming: Bool = false
    ) -> ChatSession {
        let toolCallID = "call_1"
        return ChatSession(
            id: UUID(),
            title: "Imported chat",
            createdAt: date,
            updatedAt: date,
            messages: [
                ChatTranscriptMessage(
                    role: .user,
                    content: "Read this",
                    createdAt: date,
                    imageAttachments: [
                        ChatImageAttachment(
                            filename: "notes.txt",
                            mimeType: "text/plain",
                            base64Data: attachmentData
                        )
                    ]
                ),
                ChatTranscriptMessage(
                    role: .assistant,
                    content: "",
                    createdAt: date,
                    toolCalls: [
                        MLXChatToolCall(
                            index: 0,
                            id: toolCallID,
                            type: "function",
                            function: MLXChatFunctionCall(name: "read_file", arguments: "{}")
                        )
                    ]
                ),
                ChatTranscriptMessage(
                    role: .tool,
                    content: "hello",
                    createdAt: date,
                    isStreaming: isStreaming,
                    toolCallID: toolCallID,
                    toolName: "read_file",
                    toolStatus: .running
                )
            ]
        )
    }
}
