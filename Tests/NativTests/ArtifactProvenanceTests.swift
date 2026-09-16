import XCTest

final class ArtifactProvenanceTests: XCTestCase {
    func testLegacyAttachmentDecodesWithoutInventingOrigin() throws {
        let data = Data(#"{"filename":"image-123.png","mimeType":"image/png","base64Data":"AQID"}"#.utf8)
        let attachment = try JSONDecoder().decode(ChatImageAttachment.self, from: data)
        XCTAssertNil(attachment.origin)
        XCTAssertNil(attachment.generation)
        XCTAssertEqual(attachment.assetID, attachment.id)
    }

    func testAssetIdentityComesFromStoredFileRegardlessOfAttachmentID() {
        let id = UUID()
        let asset = MediaAssetReference(relativePath: "Objects/AB/\(id).png", byteCount: 3)
        let attachment = ChatImageAttachment(id: UUID(), filename: "image.png", mimeType: "image/png", asset: asset)
        XCTAssertEqual(attachment.assetID, id)
        XCTAssertNotEqual(attachment.assetID, attachment.id)
    }

    func testRecordedOriginsAndGenerationMetadataSurviveCoding() throws {
        for origin in ArtifactSource.allCases {
            var attachment = ChatImageAttachment(filename: "image.png", mimeType: "image/png", base64Data: "AQID", origin: origin)
            attachment.generation = ArtifactGeneration(prompt: "A fox", modelID: "image/model", seed: 42, width: 64, height: 64)
            let decoded = try JSONDecoder().decode(ChatImageAttachment.self, from: JSONEncoder().encode(attachment))
            XCTAssertEqual(decoded, attachment)
        }
    }

    func testFileImportRecordsUploadOriginAndPreservesOriginal() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let input = fixture.root.appendingPathComponent("image-123.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: input)
        let attachment = try ChatImageAttachment(contentsOf: input, mediaStore: fixture.media)
        let loaded = try fixture.persist(attachment)
        XCTAssertEqual(loaded.origin, .uploaded)
        XCTAssertEqual(loaded.assetID, attachment.assetID)
        XCTAssertEqual(fixture.media.data(for: try XCTUnwrap(loaded.asset)), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testMissingOriginRemainsMissingRegardlessOfRole() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let attachment = ChatImageAttachment(filename: "generated-image.png", mimeType: "image/png", base64Data: "AQID")
        for role in [ChatTranscriptMessage.Role.user, .assistant, .tool] {
            let loaded = try fixture.persist(attachment, role: role)
            XCTAssertNil(loaded.origin)
            XCTAssertNil(loaded.generation)
        }
    }

    func testLegacyGenerationToolRecordsOriginWithoutOverridingExplicitOrigin() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        for tool in ["generate_image", "edit_image"] {
            var attachment = ChatImageAttachment(filename: "result.png", mimeType: "image/png", base64Data: "AQID")
            let generated = try fixture.persist(attachment, role: .tool, tool: tool)
            XCTAssertEqual(generated.origin, .generated)
            XCTAssertEqual(generated.generation?.prompt, "A fox")
            attachment.origin = .uploaded
            let explicit = try fixture.persist(attachment, role: .tool, tool: tool)
            XCTAssertEqual(explicit.origin, .uploaded)
        }
    }

    func testGeneratedOutputAttachmentPreservesIdentityAndMetadata() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let output = GeneratedImage(imageData: Data([1, 2, 3]), mimeType: "image/png", width: 64, height: 64, seed: 42, path: nil, revisedPrompt: "A fox", mediaStore: fixture.media)
        let attachment = output.attachment
        XCTAssertEqual(attachment.id, output.id)
        XCTAssertEqual(attachment.asset, output.asset)
        XCTAssertEqual(attachment.origin, .generated)
        XCTAssertEqual(attachment.generation, ArtifactGeneration(prompt: "A fox", seed: 42, width: 64, height: 64))
        XCTAssertEqual(try fixture.persist(attachment).generation, attachment.generation)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var media: MediaAssetStore { MediaAssetStore(rootDirectory: root.appendingPathComponent("Media")) }

        func persist(_ attachment: ChatImageAttachment, role: ChatTranscriptMessage.Role = .user, tool: String? = nil) throws -> ChatImageAttachment {
            let store = ChatSessionStore(chatDirectory: root.appendingPathComponent("Chat"), mediaStore: media)
            let message = ChatTranscriptMessage(role: role, content: "{}", imageAttachments: [attachment], toolName: tool, toolArguments: #"{"prompt":"A fox"}"#)
            let session = ChatSession(id: UUID(), title: "Test", createdAt: .now, updatedAt: .now, messages: [message])
            XCTAssertTrue(store.saveSession(session))
            return try XCTUnwrap(store.loadSession(id: session.id)?.messages.first?.imageAttachments.first)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
