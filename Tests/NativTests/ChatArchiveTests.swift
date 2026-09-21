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

    func testStoredAttachmentsRoundTripWithoutOriginalMediaStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MediaAssetStore(rootDirectory: root.appendingPathComponent("Source"))
        let destination = MediaAssetStore(rootDirectory: root.appendingPathComponent("Destination"))
        let originals = [Data([1, 2, 3]), Data([4, 5, 6]), Data("notes".utf8), Data()]
        let origins: [ArtifactSource?] = [.uploaded, .generated, .unknown, nil]
        var attachments: [ChatImageAttachment] = []
        for index in originals.indices {
            let mime = index < 2 ? "image/png" : "text/plain"
            let filename = index < 2 ? "image-\(index).png" : "notes-\(index).txt"
            let asset = try source.store(originals[index], mimeType: mime, filename: filename)
            var attachment = ChatImageAttachment(id: UUID(), filename: filename, mimeType: mime, asset: asset, origin: origins[index])
            if origins[index] == .generated {
                attachment.generation = ArtifactGeneration(prompt: "A fox", modelID: "image/model", seed: 42)
            }
            attachments.append(attachment)
        }
        var reused = attachments
        reused[0] = ChatImageAttachment(id: UUID(), filename: attachments[0].filename, mimeType: attachments[0].mimeType, asset: try XCTUnwrap(attachments[0].asset), origin: .uploaded)
        var session = makeSession()
        session.messages = [
            ChatTranscriptMessage(role: .user, content: "First use", imageAttachments: attachments),
            ChatTranscriptMessage(role: .user, content: "Reuse", imageAttachments: reused),
        ]
        let archive = ChatArchive(chat: session, modelRepositoryID: "text/model", systemPrompt: "")
        let encoded = try ChatArchiveCodec.encode(archive, mediaStore: source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let chat = try XCTUnwrap(object["chat"] as? [String: Any])
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        for message in messages {
            for attachment in try XCTUnwrap(message["imageAttachments"] as? [[String: Any]]) {
                XCTAssertNil(attachment["asset"])
                XCTAssertNotNil(attachment["base64Data"])
            }
        }
        XCTAssertNotNil(archive.chat.messages[0].imageAttachments[0].asset)
        try FileManager.default.removeItem(at: source.rootDirectory)

        let imported = try ChatArchiveCodec.importedSession(from: ChatArchiveCodec.decode(encoded))
        let store = ChatSessionStore(chatDirectory: root.appendingPathComponent("Chats"), mediaStore: destination)
        XCTAssertTrue(store.saveSession(imported))
        let reloaded = try XCTUnwrap(store.loadSession(id: imported.id))
        for index in originals.indices {
            let first = reloaded.messages[0].imageAttachments[index]
            let second = reloaded.messages[1].imageAttachments[index]
            XCTAssertEqual(first.assetID, second.assetID)
            XCTAssertNotEqual(first.assetID, attachments[index].assetID)
            XCTAssertEqual(first.origin, origins[index])
            XCTAssertEqual(first.generation, attachments[index].generation)
            XCTAssertEqual(destination.data(for: try XCTUnwrap(first.asset)), originals[index])
        }
        XCTAssertEqual(Set(reloaded.messages.flatMap(\.imageAttachments).map(\.assetID)).count, originals.count)
    }

    func testExportRejectsMissingStoredAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaAssetStore(rootDirectory: root)
        var session = makeSession()
        session.messages[0].imageAttachments = [ChatImageAttachment(
            id: UUID(), filename: "missing.png", mimeType: "image/png",
            asset: MediaAssetReference(relativePath: "Objects/missing.png", byteCount: 3)
        )]
        let archive = ChatArchive(chat: session, modelRepositoryID: "text/model", systemPrompt: "")
        XCTAssertThrowsError(try ChatArchiveCodec.encode(archive, mediaStore: media)) {
            XCTAssertEqual($0 as? ChatArchiveError, .invalidAttachment("missing.png"))
        }
    }

    func testDecodeRejectsMissingInvalidOrLocalAttachmentPayload() throws {
        let archive = ChatArchive(chat: makeSession(), modelRepositoryID: "text/model", systemPrompt: "")
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: ChatArchiveCodec.encode(archive)) as? [String: Any])
        for payload in [nil, "not base64", "aGVsbG8="] as [String?] {
            var object = valid
            var chat = try XCTUnwrap(object["chat"] as? [String: Any])
            var messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
            var attachments = try XCTUnwrap(messages[0]["imageAttachments"] as? [[String: Any]])
            attachments[0]["base64Data"] = payload
            if payload == "aGVsbG8=" {
                attachments[0]["asset"] = ["relativePath": "Objects/local.png", "byteCount": 5]
            }
            messages[0]["imageAttachments"] = attachments
            chat["messages"] = messages
            object["chat"] = chat
            XCTAssertThrowsError(try ChatArchiveCodec.decode(JSONSerialization.data(withJSONObject: object))) {
                XCTAssertEqual($0 as? ChatArchiveError, .invalidAttachment("notes.txt"))
            }
        }
    }

    func testImportRejectsDifferentBytesForTheSameAttachmentIdentity() throws {
        var session = makeSession()
        var duplicate = session.messages[0].imageAttachments[0]
        duplicate.base64Data = Data("different".utf8).base64EncodedString()
        session.messages.append(ChatTranscriptMessage(role: .user, content: "Reuse", imageAttachments: [duplicate]))
        let archive = ChatArchive(chat: session, modelRepositoryID: "text/model", systemPrompt: "")
        XCTAssertThrowsError(try ChatArchiveCodec.importedSession(from: archive)) {
            XCTAssertEqual($0 as? ChatArchiveError, .invalidAttachment("notes.txt"))
        }
    }

    func testImportPreservesSharedAssetIdentityAndGenerationMetadata() throws {
        var attachment = ChatImageAttachment(filename: "image.png", mimeType: "image/png", base64Data: Data([1, 2, 3]).base64EncodedString())
        attachment.generation = ArtifactGeneration(prompt: "A fox", modelID: "image/model", seed: 42)
        let session = ChatSession(
            id: UUID(), title: "Reuse", createdAt: .now, updatedAt: .now,
            messages: [
                ChatTranscriptMessage(role: .tool, content: "{}", imageAttachments: [attachment], toolName: "generate_image"),
                ChatTranscriptMessage(role: .user, content: "Edit this", imageAttachments: [attachment]),
            ]
        )
        let archive = ChatArchive(chat: session, modelRepositoryID: "text/model", systemPrompt: "")
        let imported = try ChatArchiveCodec.importedSession(from: archive)
        let attachments = imported.messages.flatMap(\.imageAttachments)
        XCTAssertEqual(Set(attachments.map(\.id)).count, 1)
        XCTAssertNotEqual(attachments[0].id, attachment.id)
        XCTAssertTrue(attachments.allSatisfy { $0.generation == attachment.generation })
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

    func testExportRejectsInvalidAttachmentData() throws {
        let archive = ChatArchive(
            chat: makeSession(attachmentData: "not base64"),
            modelRepositoryID: "mlx-community/Qwen3-4B",
            systemPrompt: ""
        )

        XCTAssertThrowsError(try ChatArchiveCodec.encode(archive)) { error in
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
