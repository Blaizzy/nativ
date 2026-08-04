import Foundation

@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()

    @Published private(set) var routines: [Routine] = []
    @Published private(set) var runs: [RoutineRun] = []

    var onRoutinesChanged: (() -> Void)?

    private static let maxRunsPerRoutine = 50

    init() {
        routines = Self.loadRoutines()
        runs = Self.loadRuns()
    }

    func routine(id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    func upsert(_ routine: Routine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        persistRoutines()
        onRoutinesChanged?()
    }

    func delete(id: String) {
        routines.removeAll { $0.id == id }
        runs.removeAll { $0.routineID == id }
        persistRoutines()
        persistRuns()
        onRoutinesChanged?()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else {
            return
        }
        routines[index].isEnabled = enabled
        persistRoutines()
        onRoutinesChanged?()
    }

    var scheduledRoutines: [Routine] {
        routines.filter { $0.isEnabled && $0.runsOnSchedule }
    }

    func runs(forRoutine id: String) -> [RoutineRun] {
        runs.filter { $0.routineID == id }.sorted { $0.startedAt > $1.startedAt }
    }

    func recordRun(_ run: RoutineRun) {
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        pruneRuns(forRoutine: run.routineID)
        persistRuns()
    }

    func reload() {
        routines = Self.loadRoutines()
        runs = Self.loadRuns()
    }

    private func pruneRuns(forRoutine id: String) {
        let ordered = runs
            .filter { $0.routineID == id }
            .sorted { $0.startedAt > $1.startedAt }
        guard ordered.count > Self.maxRunsPerRoutine else {
            return
        }
        let stale = Set(ordered.dropFirst(Self.maxRunsPerRoutine).map(\.id))
        runs.removeAll { stale.contains($0.id) }
    }

    private func persistRoutines() {
        Self.write(routines, to: Self.routinesURL)
    }

    private func persistRuns() {
        Self.write(runs, to: Self.runsURL)
    }

    static func loadRoutines() -> [Routine] {
        guard let data = try? Data(contentsOf: routinesURL) else {
            return []
        }
        return (try? JSONDecoder().decode([Routine].self, from: data)) ?? []
    }

    static func loadRuns() -> [RoutineRun] {
        guard let data = try? Data(contentsOf: runsURL) else {
            return []
        }
        return (try? JSONDecoder().decode([RoutineRun].self, from: data)) ?? []
    }

    static func appendRun(_ run: RoutineRun) {
        var current = loadRuns()
        if let index = current.firstIndex(where: { $0.id == run.id }) {
            current[index] = run
        } else {
            current.append(run)
        }
        write(current, to: runsURL)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static var directory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Routines", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static var routinesURL: URL {
        directory.appendingPathComponent("routines.json")
    }

    private static var runsURL: URL {
        directory.appendingPathComponent("runs.json")
    }
}
