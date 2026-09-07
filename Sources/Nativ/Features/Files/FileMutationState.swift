import Foundation

actor FilePathMutationLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor FileMutationState {
    static let shared = FileMutationState()

    private struct WriteRecord: Sendable {
        let runID: UUID
        let stamp: FileReadFileStamp?
    }

    private var locks: [String: FilePathMutationLock] = [:]
    private var reads: [UUID: [String: FileReadFileStamp]] = [:]
    private var lastWrites: [String: WriteRecord] = [:]
    private var replacementFailures: [String: Int] = [:]

    func locks(for paths: [String]) -> [FilePathMutationLock] {
        Array(Set(paths)).sorted().map { path in
            if let lock = locks[path] { return lock }
            let lock = FilePathMutationLock()
            locks[path] = lock
            return lock
        }
    }

    func recordRead(path: String, stamp: FileReadFileStamp, runID: UUID) {
        reads[runID, default: [:]][path] = stamp
    }

    func stalenessWarning(
        path: String,
        currentStamp: FileReadFileStamp?,
        runID: UUID
    ) -> String? {
        if let readStamp = reads[runID]?[path], readStamp != currentStamp {
            return
                "The file changed after this agent last read it. The edit was applied to the latest content."
        }
        if let write = lastWrites[path], write.runID != runID,
            let currentStamp, write.stamp != currentStamp
        {
            return
                "The file changed after another Nativ write. The edit was applied to the latest content."
        }
        return nil
    }

    func recordWrite(path: String, stamp: FileReadFileStamp?, runID: UUID) {
        lastWrites[path] = WriteRecord(runID: runID, stamp: stamp)
        if let stamp {
            reads[runID, default: [:]][path] = stamp
        } else {
            reads[runID]?[path] = nil
        }
    }

    func recordReplacementFailure(path: String) -> Int {
        replacementFailures[path, default: 0] += 1
        return replacementFailures[path] ?? 1
    }

    func resetReplacementFailures(paths: [String]) {
        for path in paths { replacementFailures[path] = nil }
    }
}
