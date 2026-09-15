import Foundation

/// A stable command target, without subscribing message views to chat updates.
@MainActor
final class ChatAnnotationActions: Equatable {
    private weak var chat: ChatViewModel?

    init(chat: ChatViewModel) {
        self.chat = chat
    }

    func add(_ annotation: ChatAnnotation) {
        chat?.addAnnotation(annotation)
    }

    func remove(_ id: UUID) {
        chat?.removeAnnotation(id)
    }

    func navigate(to messageID: UUID) {
        chat?.scrollTargetMessageID = messageID
    }

    nonisolated static func == (lhs: ChatAnnotationActions, rhs: ChatAnnotationActions) -> Bool {
        lhs === rhs
    }
}
