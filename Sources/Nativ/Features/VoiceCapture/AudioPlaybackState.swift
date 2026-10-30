import Combine
import Foundation

struct AudioPlaybackExcerpt: Equatable {
    let start: TimeInterval
    let end: TimeInterval

    init?(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else { return nil }
        let start = min(max(0, start), duration)
        let end = min(max(0, end), duration)
        guard end > start else { return nil }
        self.start = start
        self.end = end
    }
}

@MainActor
final class AudioPlaybackState: ObservableObject {
    @Published var recordID: String?
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1
    @Published var excerpt: AudioPlaybackExcerpt?

    func reset() {
        recordID = nil
        position = 0
        duration = 0
        excerpt = nil
    }
}
