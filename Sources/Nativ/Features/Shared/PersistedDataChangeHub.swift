import Combine
import Foundation

struct PersistedDataChange: Equatable {
    enum Kind: Equatable {
        case chatSession(UUID)
        case chatFolders
        case imageGenerationSession(UUID)
    }

    let originWindowID: UUID
    let kind: Kind
}

@MainActor
final class PersistedDataChangeHub {
    let changes = PassthroughSubject<PersistedDataChange, Never>()

    func send(_ kind: PersistedDataChange.Kind, originWindowID: UUID) {
        changes.send(PersistedDataChange(originWindowID: originWindowID, kind: kind))
    }
}
