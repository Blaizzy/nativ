import AppKit
import Foundation

enum RoutineLaunchAgent {
    private static let labelPrefix = "dev.local.Nativ.routine."

    static func refresh(routines: [Routine]) {
        guard let directory = launchAgentsDirectory,
              let executablePath = Bundle.main.executablePath
        else {
            return
        }

        let scheduled = routines.filter { $0.isEnabled && $0.runsOnSchedule }
        let desiredLabels = Set(scheduled.map { labelPrefix + $0.id })

        if let existing = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in existing where url.lastPathComponent.hasPrefix(labelPrefix) {
                let label = url.deletingPathExtension().lastPathComponent
                if !desiredLabels.contains(label) {
                    unload(url)
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        for routine in scheduled {
            let label = labelPrefix + routine.id
            let url = directory.appendingPathComponent(label + ".plist")
            let plist = makePlist(
                label: label,
                executablePath: executablePath,
                routineID: routine.id,
                schedule: routine.schedule
            )
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            ) else {
                continue
            }
            unload(url)
            try? data.write(to: url, options: .atomic)
            load(url)
        }
    }

    private static func makePlist(
        label: String,
        executablePath: String,
        routineID: String,
        schedule: RoutineSchedule
    ) -> [String: Any] {
        let intervals: [[String: Int]]
        if schedule.runsEveryDay {
            intervals = [["Hour": schedule.hour, "Minute": schedule.minute]]
        } else {
            intervals = schedule.weekdays.sorted().map { weekday in
                ["Weekday": weekday - 1, "Hour": schedule.hour, "Minute": schedule.minute]
            }
        }
        return [
            "Label": label,
            "ProgramArguments": [executablePath, "--run-routine", routineID],
            "StartCalendarInterval": intervals,
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
    }

    private static var launchAgentsDirectory: URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func load(_ url: URL) {
        runLaunchctl(["load", "-w", url.path])
    }

    private static func unload(_ url: URL) {
        runLaunchctl(["unload", url.path])
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
enum RoutineHeadlessRun {
    private static var retainedRunner: RoutineRunner?
    private static var retainedModel: NativModel?

    static func execute(routineID: String) {
        if anotherInstanceRunning() {
            exit(EXIT_SUCCESS)
        }
        guard RoutineScheduler.hasSufficientBattery(),
              let routine = RoutineStore.shared.routine(id: routineID)
        else {
            exit(EXIT_SUCCESS)
        }
        let model = NativModel()
        let runner = RoutineRunner(
            model: model,
            store: RoutineStore.shared,
            sessionStore: ChatSessionStore()
        )
        retainedModel = model
        retainedRunner = runner
        runner.onRunCompleted = { routine, run in
            Task { @MainActor in
                if routine.notifyOnFinish {
                    await NativNotificationService.shared.deliver(
                        .scheduledTaskCompletion(routine: routine, run: run)
                    )
                }
                model.stopServer()
                exit(EXIT_SUCCESS)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            retainedModel?.stopServer()
            exit(EXIT_SUCCESS)
        }
        runner.run(routine, source: .scheduled)
        RunLoop.main.run()
    }

    private static func anotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return false
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }
}
