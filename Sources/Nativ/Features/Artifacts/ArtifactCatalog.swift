import Foundation
import UniformTypeIdentifiers

enum ArtifactCatalog {
    static func artifacts(chats: [ChatSession], images: [ImageGenerationSession],
                          chatStore: ChatSessionStore = .init(), includeUnavailableWorkFiles: Bool = false) -> [Artifact] {
        var entries: [Artifact] = []
        for session in chats {
            entries += workDocuments(in: session, store: chatStore, includeUnavailable: includeUnavailableWorkFiles)
            for message in session.messages {
                for attachment in message.imageAttachments {
                    let generation = message.artifactGeneration(for: attachment)
                    append(
                        attachment, generation: generation,
                        usage: ArtifactUsage(workspace: .chat, sessionID: session.id,
                                             messageID: message.id, attachmentID: attachment.id,
                                             isGenerationOutput: message.isImageGenerationResult),
                        title: session.displayTitle, date: message.createdAt,
                        prompt: generation?.prompt ?? message.content, to: &entries
                    )
                }
            }
        }
        for session in images {
            if let reference = session.activeReference {
                append(
                    reference, generation: reference.generation,
                    usage: ArtifactUsage(workspace: .imageGeneration, sessionID: session.id,
                                         messageID: nil, attachmentID: reference.id),
                    title: session.displayTitle, date: session.createdAt, prompt: nil, to: &entries
                )
            }
            for turn in session.turns {
                for reference in turn.referenceImages {
                    append(
                        reference, generation: reference.generation,
                        usage: ArtifactUsage(workspace: .imageGeneration, sessionID: session.id,
                                             messageID: turn.id, attachmentID: reference.id),
                        title: session.displayTitle, date: turn.createdAt, prompt: nil, to: &entries
                    )
                }
                for output in turn.outputs {
                    var attachment = output.attachment
                    attachment.generation?.prompt = output.revisedPrompt ?? turn.prompt
                    attachment.generation?.modelID = turn.modelID
                    append(
                        attachment, generation: attachment.generation,
                        usage: ArtifactUsage(workspace: .imageGeneration, sessionID: session.id,
                                             messageID: turn.id, attachmentID: output.id, isGenerationOutput: true),
                        title: session.displayTitle, date: turn.createdAt,
                        prompt: attachment.generation?.prompt, to: &entries
                    )
                }
            }
        }
        let groups = Dictionary(grouping: entries, by: \.id)
        return groups.values.compactMap { group in
            let ordered = group.sorted {
                if ($0.source != .unknown) != ($1.source != .unknown) {
                    return $0.source != .unknown
                }
                if ($0.generation != nil) != ($1.generation != nil) {
                    return $0.generation != nil
                }
                if $0.locations[0].isGenerationOutput != $1.locations[0].isGenerationOutput {
                    return $0.locations[0].isGenerationOutput
                }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                if ($0.locations[0].messageID != nil) != ($1.locations[0].messageID != nil) {
                    return $0.locations[0].messageID != nil
                }
                return $0.sessionID.uuidString < $1.sessionID.uuidString
            }
            guard var artifact = ordered.first else { return nil }
            let origins = Set(group.map(\.source).filter { $0 != .unknown })
            if origins.count > 1 { artifact.source = .unknown }
            var seen: Set<ArtifactUsage> = []
            artifact.usages = ordered.flatMap(\.locations).filter { seen.insert($0).inserted }
            return artifact
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func workDocuments(in session: ChatSession, store: ChatSessionStore, includeUnavailable: Bool) -> [Artifact] {
        if session.workFilesInWorktree == true, session.worktree?.isReady != true { return [] }
        let files = session.workFilesInWorktree == true
            ? store.workFiles(for: session.worktree) : store.workFiles
        return (session.workState?.items ?? []).compactMap { item in
            guard item.canEdit, let url = files.fileURL(for: item, sessionID: session.id) else { return nil }
            let values = files.validatedURL(url).flatMap {
                try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
            }
            guard includeUnavailable || values?.isRegularFile == true else { return nil }
            // Forked chats can retain item IDs but own different files.
            let id = ArtifactFileManifest.artifactID(session: session.id, item: item.id)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "text/plain"
            return Artifact(
                id: id, kind: .document, source: .unknown,
                sessionID: session.id, messageID: session.id,
                filename: url.lastPathComponent, mimeType: mime, relativePath: "",
                byteSize: values?.fileSize ?? 0, createdAt: values?.creationDate ?? session.createdAt,
                prompt: nil, sessionTitle: session.displayTitle, workFileURL: url,
                workFileRoot: files.root, workFileWorktree: files.worktree,
                usages: [ArtifactUsage(workspace: .chat, sessionID: session.id,
                                       messageID: nil, attachmentID: item.id)]
            )
        }
    }

    static func availableWorkFile(_ candidate: Artifact) -> Artifact? {
        guard let url = candidate.validatedWorkFileURL,
              let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey]),
              values.isRegularFile == true else { return nil }
        var artifact = candidate
        artifact.byteSize = values.fileSize ?? 0
        artifact.createdAt = values.creationDate ?? candidate.createdAt
        return artifact
    }

    private static func append(
        _ attachment: ChatImageAttachment, generation: ArtifactGeneration?, usage: ArtifactUsage,
        title: String, date: Date, prompt: String?, to entries: inout [Artifact]
    ) {
        guard let asset = attachment.asset else { return }
        entries.append(Artifact(
            id: attachment.assetID,
            kind: ArtifactKind.resolve(mimeType: attachment.mimeType, filename: attachment.filename),
            source: attachment.origin ?? (generation == nil ? .unknown : .generated),
            sessionID: usage.sessionID, messageID: usage.messageID ?? usage.sessionID,
            filename: attachment.filename, mimeType: attachment.mimeType,
            relativePath: asset.relativePath, byteSize: asset.byteCount, createdAt: date,
            prompt: prompt?.isEmpty == false ? prompt : nil, sessionTitle: title,
            asset: asset, generation: generation, usages: [usage]
        ))
    }
}

extension ChatSession {
    mutating func removeArtifact(_ assetID: UUID) {
        for index in messages.indices {
            messages[index].imageAttachments.removeAll { $0.assetID == assetID }
        }
    }
}

extension ImageGenerationSession {
    mutating func removeArtifact(_ assetID: UUID) {
        for index in turns.indices {
            turns[index].referenceImages.removeAll { $0.assetID == assetID }
            turns[index].outputs.removeAll { ($0.asset?.id ?? $0.id) == assetID }
        }
        if activeReference?.assetID == assetID { activeReference = nil }
    }
}

enum ArtifactDeletion {
    static func removeReferences(
        to artifact: Artifact,
        isActive: (ArtifactUsage.Workspace, UUID) -> Bool,
        remove: (ArtifactUsage.Workspace, UUID) -> Bool
    ) -> Bool {
        let chats = Set(artifact.locations.filter { $0.workspace == .chat }.map(\.sessionID))
        let images = Set(artifact.locations.filter { $0.workspace == .imageGeneration }.map(\.sessionID))
        guard chats.allSatisfy({ !isActive(.chat, $0) }),
              images.allSatisfy({ !isActive(.imageGeneration, $0) }) else { return false }
        for id in chats.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard remove(.chat, id) else { return false }
        }
        for id in images.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard remove(.imageGeneration, id) else { return false }
        }
        return true
    }
}
