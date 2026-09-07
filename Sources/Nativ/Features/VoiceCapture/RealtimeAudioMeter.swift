import Foundation
import Synchronization

struct RealtimeAudioMeterSnapshot: Equatable, Sendable {
    let level: Float
    let elapsed: TimeInterval
    let revision: UInt64
}

enum RealtimeAudioMeterProfile: Sendable {
    case inputMonitor
    case recording

    func smoothedLevel(previous: Float, input: Float) -> Float {
        let clamped = max(0, min(1, input))
        switch self {
        case .inputMonitor:
            return (previous * 0.65) + (clamped * 0.35)
        case .recording:
            let shaped = pow(clamped, 0.72)
            return (previous * 0.68) + (shaped * 0.32)
        }
    }
}

final class RealtimeAudioMeter: Sendable {
    private let profile: RealtimeAudioMeterProfile
    private let smoothedLevelBits = Atomic<UInt32>(0)
    private let latestElapsedBits = Atomic<UInt64>(0)
    private let sequence = Atomic<UInt64>(0)

    init(profile: RealtimeAudioMeterProfile) {
        self.profile = profile
    }

    func submit(level: Float, elapsed: TimeInterval) {
        let previous = Float(
            bitPattern: smoothedLevelBits.load(ordering: .relaxed)
        )
        let smoothed = profile.smoothedLevel(previous: previous, input: level)

        // Odd sequence values identify a write in progress. The release on the
        // final increment publishes both value stores to the consumer.
        _ = sequence.add(1, ordering: .acquiringAndReleasing)
        smoothedLevelBits.store(smoothed.bitPattern, ordering: .relaxed)
        latestElapsedBits.store(elapsed.bitPattern, ordering: .relaxed)
        _ = sequence.add(1, ordering: .releasing)
    }

    func snapshot(after lastRevision: UInt64) -> RealtimeAudioMeterSnapshot? {
        let startingSequence = sequence.load(ordering: .acquiring)
        guard startingSequence != lastRevision,
            startingSequence.isMultiple(of: 2)
        else {
            return nil
        }

        let level = Float(
            bitPattern: smoothedLevelBits.load(ordering: .relaxed)
        )
        let elapsed = TimeInterval(
            bitPattern: latestElapsedBits.load(ordering: .relaxed)
        )
        let endingSequence = sequence.load(ordering: .acquiring)
        guard startingSequence == endingSequence else {
            return nil
        }

        return RealtimeAudioMeterSnapshot(
            level: level,
            elapsed: elapsed,
            revision: endingSequence
        )
    }
}

enum RealtimeAudioMeterPublisher {
    static let publishInterval: Duration = .nanoseconds(66_666_667)

    @concurrent
    static func run(
        meter: RealtimeAudioMeter,
        interval: Duration = publishInterval,
        deliver: @escaping @MainActor @Sendable (RealtimeAudioMeterSnapshot) -> Void
    ) async {
        var deliveredRevision: UInt64 = 0

        while !Task.isCancelled {
            if let snapshot = meter.snapshot(after: deliveredRevision) {
                deliveredRevision = snapshot.revision
                await deliver(snapshot)
            }

            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
