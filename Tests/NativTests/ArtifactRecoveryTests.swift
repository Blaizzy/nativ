import XCTest

final class ArtifactRecoveryTests: XCTestCase {
    func testRestorationPreservesEditsOrderAndDistinctAttachmentIDs() throws {
        let assetID = UUID()
        let asset = MediaAssetReference(relativePath: "Objects/\(assetID).png", byteCount: 3)
        let attachment = ChatImageAttachment(id: UUID(), filename: "fox.png", mimeType: "image/png", asset: asset)
        let other = ChatImageAttachment(id: UUID(), filename: "other.png", mimeType: "image/png",
                                        asset: MediaAssetReference(relativePath: "Objects/\(UUID()).png", byteCount: 1))
        let reused = ChatImageAttachment(id: UUID(), filename: attachment.filename, mimeType: attachment.mimeType, asset: asset)
        var chat = ChatSession(id: UUID(), title: "Chat", createdAt: .now, updatedAt: .now, messages: [
            ChatTranscriptMessage(role: .user, content: "Original", imageAttachments: [other, attachment, reused])
        ])
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [chat], images: []).first { $0.id == assetID })
        let recovery = ArtifactRecovery(artifact: artifact, originalURL: URL(fileURLWithPath: "/unused"), chats: [chat], images: [])
        let decoded = try JSONDecoder().decode(ArtifactRecovery.self, from: JSONEncoder().encode(recovery))
        chat.removeArtifact(assetID)
        XCTAssertEqual(chat.messages[0].imageAttachments, [other])
        chat.messages[0].content = "Edited while deleted"
        XCTAssertEqual(decoded.restore(into: &chat), 2)
        XCTAssertEqual(decoded.restore(into: &chat), 2)
        XCTAssertEqual(chat.messages[0].imageAttachments, [other, attachment, reused])
        XCTAssertEqual(chat.messages[0].content, "Edited while deleted")
        chat.messages = []
        XCTAssertEqual(decoded.restore(into: &chat), 0)
    }

    func testGeneratedOutputMetadataAndReferencesSurviveRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = MediaAssetStore(rootDirectory: root)
        let output = GeneratedImage(imageData: Data([1, 2, 3]), mimeType: "image/png", width: 640,
                                    height: 480, seed: 42, path: "original", revisedPrompt: "A fox", mediaStore: media)
        let turn = ImageGenerationTurn(id: UUID(), prompt: "Fox", referenceImages: [output.attachment], modelID: "test",
                                       settings: ImageRequestSettings(), createdAt: .now, outputs: [output], status: .completed)
        var image = ImageGenerationSession(id: UUID(), title: "Images", createdAt: .now, updatedAt: .now,
                                           modelKind: .imageGeneration, modelID: "test", draftSettings: ImageRequestSettings(),
                                           activeReference: output.attachment, turns: [turn])
        let artifact = try XCTUnwrap(ArtifactCatalog.artifacts(chats: [], images: [image]).first)
        let recovery = ArtifactRecovery(artifact: artifact, originalURL: root, chats: [], images: [image])
        let decoded = try JSONDecoder().decode(ArtifactRecovery.self, from: JSONEncoder().encode(recovery))
        image.removeArtifact(artifact.id)
        XCTAssertTrue(image.turns[0].outputs.isEmpty)
        XCTAssertNil(image.activeReference)
        XCTAssertEqual(decoded.restore(into: &image), 3)
        XCTAssertEqual(decoded.restore(into: &image), 3)
        XCTAssertEqual(image.turns[0].outputs, [output])
        XCTAssertEqual(image.turns[0].referenceImages, [output.attachment])
        XCTAssertEqual(image.activeReference, output.attachment)
        image.activeReference = ChatImageAttachment(filename: "new.png", mimeType: "image/png", base64Data: "")
        XCTAssertEqual(decoded.restore(into: &image), 2)
        XCTAssertEqual(image.activeReference?.filename, "new.png")
    }
}
