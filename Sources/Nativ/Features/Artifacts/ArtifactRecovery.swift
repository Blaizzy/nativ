import Foundation

/// Only the removed references are saved; restoring never replaces a conversation snapshot.
struct ArtifactRecovery: Codable, Identifiable {
    struct Reference: Codable {
        let usage: ArtifactUsage
        let index: Int
        let attachment: ChatImageAttachment
        var output: GeneratedImage? = nil
    }

    let artifact: Artifact
    let originalURL: URL
    var trashURL: URL?
    let deletedAt: Date
    let references: [Reference]
    let recoveredChatID: UUID
    var id: UUID { artifact.id }

    init(artifact: Artifact, originalURL: URL, chats: [ChatSession], images: [ImageGenerationSession]) {
        self.artifact = artifact
        self.originalURL = originalURL
        deletedAt = .now
        recoveredChatID = UUID()
        var references: [Reference] = []
        for chat in chats {
            for message in chat.messages {
                for (index, attachment) in message.imageAttachments.enumerated() where attachment.assetID == artifact.id {
                    references.append(Reference(
                        usage: ArtifactUsage(workspace: .chat, sessionID: chat.id, messageID: message.id,
                                             attachmentID: attachment.id),
                        index: index, attachment: attachment
                    ))
                }
            }
        }
        for image in images {
            if let attachment = image.activeReference, attachment.assetID == artifact.id {
                references.append(Reference(
                    usage: ArtifactUsage(workspace: .imageGeneration, sessionID: image.id,
                                         messageID: nil, attachmentID: attachment.id),
                    index: 0, attachment: attachment
                ))
            }
            for turn in image.turns {
                for (index, attachment) in turn.referenceImages.enumerated() where attachment.assetID == artifact.id {
                    references.append(Reference(
                        usage: ArtifactUsage(workspace: .imageGeneration, sessionID: image.id,
                                             messageID: turn.id, attachmentID: attachment.id),
                        index: index, attachment: attachment
                    ))
                }
                for (index, output) in turn.outputs.enumerated() where (output.asset?.id ?? output.id) == artifact.id {
                    references.append(Reference(
                        usage: ArtifactUsage(workspace: .imageGeneration, sessionID: image.id,
                                             messageID: turn.id, attachmentID: output.id, isGenerationOutput: true),
                        index: index, attachment: output.attachment, output: output
                    ))
                }
            }
        }
        self.references = references
    }

    /// Returns the number of original locations still present, including already restored ones.
    @discardableResult
    func restore(into chat: inout ChatSession) -> Int {
        var restored = 0
        for reference in references where reference.usage.workspace == .chat && reference.usage.sessionID == chat.id {
            guard let index = chat.messages.firstIndex(where: { $0.id == reference.usage.messageID }) else { continue }
            Self.insert(reference.attachment, at: reference.index, into: &chat.messages[index].imageAttachments)
            restored += 1
        }
        return restored
    }

    @discardableResult
    func restore(into image: inout ImageGenerationSession) -> Int {
        var restored = 0
        for reference in references where reference.usage.workspace == .imageGeneration && reference.usage.sessionID == image.id {
            if reference.usage.messageID == nil {
                // A new active reference belongs to the user's current draft.
                guard image.activeReference == nil || image.activeReference?.id == reference.attachment.id else { continue }
                image.activeReference = reference.attachment
            } else {
                guard let index = image.turns.firstIndex(where: { $0.id == reference.usage.messageID }) else { continue }
                if let output = reference.output {
                    Self.insert(output, at: reference.index, into: &image.turns[index].outputs)
                } else {
                    Self.insert(reference.attachment, at: reference.index, into: &image.turns[index].referenceImages)
                }
            }
            restored += 1
        }
        return restored
    }

    private static func insert<T: Identifiable>(_ item: T, at index: Int, into items: inout [T]) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: min(index, items.count))
    }
}
