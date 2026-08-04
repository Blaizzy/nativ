import Foundation
import IOKit.ps

@MainActor
final class RoutineScheduler {
    private let store: RoutineStore
    private let onFire: (Routine, RoutineRunSource) -> Void
    private var timer: Timer?
    private var lastFiredScheduledDate: [String: Date] = [:]

    private static let tickInterval: TimeInterval = 30
    private static let lookbackWindow: TimeInterval = 90

    init(store: RoutineStore, onFire: @escaping (Routine, RoutineRunSource) -> Void) {
        self.store = store
        self.onFire = onFire
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        for routine in store.scheduledRoutines {
            guard let due = dueScheduledDate(for: routine, now: now) else {
                continue
            }
            if lastFiredScheduledDate[routine.id] == due {
                continue
            }
            lastFiredScheduledDate[routine.id] = due
            guard Self.hasSufficientBattery() else {
                continue
            }
            onFire(routine, .scheduled)
        }
    }

    private func dueScheduledDate(for routine: Routine, now: Date) -> Date? {
        guard let candidate = routine.schedule.nextFireDate(
            after: now.addingTimeInterval(-Self.lookbackWindow)
        ) else {
            return nil
        }
        return candidate <= now ? candidate : nil
    }

    static func hasSufficientBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any]
        else {
            return true
        }

        if description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
            return true
        }

        if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
           let maximum = description[kIOPSMaxCapacityKey] as? Int,
           maximum > 0 {
            return Double(capacity) / Double(maximum) >= 0.10
        }

        return true
    }
}
