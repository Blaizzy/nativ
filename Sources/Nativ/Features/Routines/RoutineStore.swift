import Combine
import Foundation

@MainActor
final class RoutineStore: ObservableObject {
    struct Persistence {
        let directory: URL

        init(directory: URL = RoutineStore.defaultDirectory) {
            self.directory = directory
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var routinesURL: URL {
            directory.appendingPathComponent("routines.json")
        }

        var runsURL: URL {
            directory.appendingPathComponent("runs.json")
        }
    }

    static let shared = RoutineStore()

    @Published private(set) var routines: [Routine] = []
    @Published private(set) var runs: [RoutineRun] = []

    var onRoutinesChanged: (() -> Void)?
    var onRoutineDeleted: ((String) -> Void)?

    private static let maxRunsPerRoutine = 50
    private let persistence: Persistence

    init(persistence: Persistence = Persistence()) {
        self.persistence = persistence
        routines = Self.loadRoutines(from: persistence.routinesURL)
        runs = Self.loadRuns(from: persistence.runsURL)
    }

    func routine(id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    func routine(forSession sessionID: UUID) -> Routine? {
        routines.first { $0.sourceSessionID == sessionID }
    }

    func deleteRoutine(forSession sessionID: UUID) {
        guard let routine = routine(forSession: sessionID) else {
            return
        }
        delete(id: routine.id)
    }

    func isRoutineRunning(forSession sessionID: UUID) -> Bool {
        guard let routine = routine(forSession: sessionID) else {
            return false
        }
        return runs.contains { $0.routineID == routine.id && $0.status == .running }
    }

    func upsert(_ routine: Routine) {
        guard let sourceSessionID = routine.sourceSessionID,
              !sourceSessionID.uuidString.isEmpty
        else {
            return
        }
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        persistRoutines()
        onRoutinesChanged?()
    }

    func delete(id: String) {
        guard routines.contains(where: { $0.id == id }) else {
            return
        }
        onRoutineDeleted?(id)
        routines.removeAll { $0.id == id }
        runs.removeAll { $0.routineID == id }
        persistRoutines()
        persistRuns()
        onRoutinesChanged?()
    }

    /// Removes persisted routines whose source chat no longer exists.
    ///
    /// This repairs older installations where a chat was deleted through a path
    /// that did not also delete its routine. A routine without a source session
    /// cannot safely append its result anywhere, so it is orphaned as well.
    @discardableResult
    func reconcile(sourceSessionIDs: Set<UUID>) -> [String] {
        let orphanedIDs = routines.compactMap { routine in
            guard let sourceSessionID = routine.sourceSessionID,
                  sourceSessionIDs.contains(sourceSessionID)
            else {
                return routine.id
            }
            return nil
        }
        guard !orphanedIDs.isEmpty else {
            return []
        }
        for id in orphanedIDs {
            onRoutineDeleted?(id)
        }
        let orphaned = Set(orphanedIDs)
        routines.removeAll { orphaned.contains($0.id) }
        runs.removeAll { orphaned.contains($0.routineID) }
        persistRoutines()
        persistRuns()
        onRoutinesChanged?()
        return orphanedIDs
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
        // A runner may finish after its routine was deleted. Do not resurrect
        // run history for a routine that is no longer part of the store.
        guard routines.contains(where: { $0.id == run.routineID }) else {
            return
        }
        if let index = runs.firstIndex(where: { $0.id == run.id }) {
            runs[index] = run
        } else {
            runs.append(run)
        }
        pruneRuns(forRoutine: run.routineID)
        persistRuns()
    }

    func reload() {
        routines = Self.loadRoutines(from: persistence.routinesURL)
        runs = Self.loadRuns(from: persistence.runsURL)
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
        Self.write(routines, to: persistence.routinesURL)
    }

    private func persistRuns() {
        Self.write(runs, to: persistence.runsURL)
    }

    static func loadRoutines() -> [Routine] {
        loadRoutines(from: Persistence().routinesURL)
    }

    static func loadRuns() -> [RoutineRun] {
        loadRuns(from: Persistence().runsURL)
    }

    static func appendRun(_ run: RoutineRun) {
        var current = loadRuns()
        if let index = current.firstIndex(where: { $0.id == run.id }) {
            current[index] = run
        } else {
            current.append(run)
        }
        write(current, to: Persistence().runsURL)
    }

    private static func loadRoutines(from url: URL) -> [Routine] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([Routine].self, from: data)) ?? []
    }

    private static func loadRuns(from url: URL) -> [RoutineRun] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? JSONDecoder().decode([RoutineRun].self, from: data)) ?? []
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated fileprivate static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Routines", isDirectory: true)
    }
}
