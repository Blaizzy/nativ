extension NativNotification {
    static func scheduledTaskCompletion(
        routine: Routine,
        run: RoutineRun
    ) -> NativNotification {
        let metadata = run.sessionID.map {
            ["sessionID": $0.uuidString]
        } ?? [:]

        return NativNotification(
            identifier: run.id,
            title: run.status == .failed
                ? "Your scheduled task failed"
                : "Your scheduled task completed",
            body: routine.name.isEmpty ? "Scheduled task" : routine.name,
            metadata: metadata
        )
    }
}
