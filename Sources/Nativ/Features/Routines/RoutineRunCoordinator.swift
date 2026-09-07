import Foundation

@MainActor
final class RoutineRunCoordinator {
    static let shared = RoutineRunCoordinator()

    private var runner: RoutineRunner?

    func configure(runner: RoutineRunner) {
        self.runner = runner
    }

    func run(_ routine: Routine, source: RoutineRunSource) {
        runner?.run(routine, source: source)
    }

    func cancel(routineID: String) {
        runner?.cancel(routineID: routineID)
    }

    func runRoutine(id: String, source: RoutineRunSource) {
        guard let routine = RoutineStore.shared.routine(id: id) else {
            return
        }
        run(routine, source: source)
    }
}
