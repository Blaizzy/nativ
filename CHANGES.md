Yes, we should unify **ownership and lifecycle**, but I would **not** merge everything into one giant class.

The correct design is:

- One aggregate/store owns a chat session and its optional routine.
- Scheduling, execution, launchd, and model/network work remain separate services.
- A routine should never be able to outlive its source chat.

## Confirmed issues

### 1. Bulk chat deletion leaves routines orphaned — P0

In `ControlPanelView.swift`:

- `deleteRecentSession(_:)` deletes the routine before deleting the chat.
- `bulkDeleteSelected()` deletes only the chat.

Therefore bulk deletion can leave:

```text
routines.json
launchd plist
runs.json
```

for a chat that no longer exists.

The scheduler still sees the orphaned routine and can continue running it.

### 2. Deleting a routine does not cancel active execution — P0

`RoutineStore.delete(id:)` removes persisted state, but it does not communicate with:

- `RoutineRunner`
- `RoutineRunCoordinator`
- `RoutineHeadlessRun`
- an already-running launchd process

A routine already queued or running owns a copied `Routine` value, so deleting the store entry does not invalidate that work.

### 3. A completed deleted run can recreate persisted state — P0

After deletion, `RoutineRunner` can still call:

```swift
store.recordRun(run)
```

`recordRun` does not verify that the routine still exists. This can recreate a run record for a deleted routine.

### 4. A deleted chat can be recreated after a run completes — P0

`RoutineRunner.appendRun(...)` does this:

1. Tries to load the routine’s source session.
2. If it is missing, falls through to `makeSession(...)`.
3. Saves a new chat containing the routine output.

So deleting a routine chat while its run is active can result in a new chat being created when the old run finishes.

### 5. The UI cannot accurately represent deleted/running state — P1

`isRoutineRunning(forSession:)` first looks up the routine. Once the routine is deleted, it returns `false` regardless of whether an active runner still exists.

This means the UI hides the active state instead of showing “cancelling” or “cancelled.”

### 6. No startup reconciliation — P1

At startup, the app loads:

- chat sessions from `Caches/Nativ/Chat/Sessions`
- routines from `Application Support/Nativ/Routines/routines.json`

There is no reconciliation step that asks:

```text
Does every routine sourceSessionID still refer to a real chat?
```

Orphaned routines therefore survive restarts.

### 7. Chat and routine persistence is not atomic — P1

Creating or deleting a routine chat touches multiple independent files:

- chat session JSON
- `routines.json`
- `runs.json`
- launchd plist

Each write uses `try?`, so failures are silently ignored. A crash or write failure between operations can leave partial state.

Examples:

- routine exists but chat creation failed
- chat exists but routine write failed
- routine deleted but launchd cleanup failed
- run deleted, then recreated by an active runner

### 8. Chat data is stored under `Caches` — P1

`ChatSessionStore` stores user chat history under:

```text
~/Library/Caches/Nativ/Chat/Sessions
```

Caches are purgeable by macOS. Routine definitions are stored under Application Support, so cache eviction can create missing-source routines.

User chat history should be under Application Support, not Caches.

### 9. Stale `.running` records are never recovered — P1

`RoutineRunStatus` has:

```swift
.running
.succeeded
.failed
```

If the app or headless process crashes, a run can remain `.running` forever.

The 600-second headless timeout also calls `exit()` without finalizing the run status.

### 10. Cross-process writes can race — P1

The GUI process and headless launch-agent process can both write `runs.json`.

`RoutineStore.appendRun(_:)` performs:

```swift
loadRuns()
modify
write()
```

without a file lock or interprocess coordination. Concurrent runs can lose updates or overwrite each other.

### 11. Launch-agent state is not verified — P2

`RoutineLaunchAgent`:

- swallows `launchctl` errors
- uses deprecated-style `load`/`unload` calls
- does not verify that the desired job is actually loaded
- has no explicit running-process registry

A plist disappearing from disk does not necessarily mean an already-running process has stopped.

### 12. Scheduler state is only in memory — P2

`lastFiredScheduledDate` is lost on restart. The 90-second lookback can cause a routine to fire again after restarting near its scheduled time.

There is no persistent run idempotency key for a scheduled occurrence.

### 13. Routine lifecycle is duplicated across UI paths — P1

Routine deletion currently exists in:

- routine editor deletion
- single chat deletion
- bulk chat deletion
- possibly future API/UI paths

Because ownership is not centralized, every new deletion path can repeat this bug.

### 14. No meaningful routine lifecycle tests — P1

The current design needs tests for:

- single deletion
- bulk deletion
- routine-editor deletion
- active deletion
- queued deletion
- startup reconciliation
- missing source chats
- launch-agent cleanup
- timeout/crash recovery
- migration of existing files

## Recommended architecture

### Keep the models separate, but create one aggregate

I recommend replacing `RoutineStore` plus the chat persistence boundary with:

```swift
@MainActor
final class SessionStore: ObservableObject
```

A session becomes the aggregate root:

```swift
struct SessionRecord: Identifiable, Codable {
    var chat: ChatSession
    var routine: RoutineConfiguration?
}
```

The important relationship becomes structural:

```text
SessionRecord
├── ChatSession
├── optional RoutineConfiguration
└── RoutineRun history
```

A routine no longer owns a fragile `sourceSessionID` foreign key. The session owns the routine.

`RoutineRun` should use the session ID:

```swift
struct RoutineRun: Codable, Identifiable {
    var id: String
    var sessionID: UUID
    var startedAt: Date
    var finishedAt: Date?
    var status: RoutineRunStatus
    var source: RoutineRunSource
    var resultSummary: String
}
```

The existing `Routine` model can remain conceptually separate, but it should become configuration attached to a session.

## Responsibilities of `SessionStore`

`SessionStore` should be the only public owner of session/routine lifecycle operations:

```swift
func createSession() -> SessionRecord
func deleteSession(id: UUID)
func attachRoutine(_ routine: RoutineConfiguration, to sessionID: UUID)
func updateRoutine(_ routine: RoutineConfiguration, for sessionID: UUID)
func deleteRoutine(from sessionID: UUID)
func recordRun(_ run: RoutineRun)
func cancelRoutine(for sessionID: UUID)
func reconcile()
```

Critical invariants:

1. A routine cannot exist without a session.
2. Deleting a session always deletes or tombstones its routine.
3. Deleting a routine never deletes its chat.
4. No runner may append to a deleted session.
5. No run may be recorded for a missing/deleted routine.
6. Every persisted running run is resolved on startup.
7. All UI deletion paths call the same `SessionStore.deleteSession`.

## Services that should remain separate

### `SessionRepository`

Handles persistence only:

```swift
actor SessionRepository
```

Recommended storage:

```text
~/Library/Application Support/Nativ/Sessions/<session-id>/
    session.json
    runs/
        <run-id>.json
```

This keeps chat history from becoming one huge global JSON file while placing related data under one ownership boundary.

It should provide:

- atomic writes
- migration
- file locking/interprocess coordination
- error reporting instead of silent `try?`
- recovery of partially written data

### `RoutineScheduler`

Only determines which session IDs are due.

It should enqueue:

```text
sessionID + scheduledOccurrenceID
```

rather than copying an entire `Routine`.

Before execution it must re-fetch and validate the current session. If the routine was deleted or disabled, it skips the run.

### `RoutineRunCoordinator`

Owns active and queued run tasks:

```swift
func enqueue(sessionID: UUID, source: RoutineRunSource)
func cancel(sessionID: UUID)
func cancel(runID: String)
```

It should:

- remove queued runs on deletion
- cancel active `Task`s
- prevent completion callbacks after cancellation
- check cancellation before persisting output
- mark runs `.cancelled`
- prevent duplicate runs for the same scheduled occurrence

### `RoutineLaunchAgentManager`

Owns launchd only:

```swift
func reconcile(scheduledSessionIDs: Set<UUID>)
func remove(sessionID: UUID)
func terminateActiveRun(sessionID: UUID)
```

It should use a protocol so tests can use a fake launchd implementation.

## Persistence migration

The migration should be one-time and safe:

1. Load existing chat sessions from `Caches/Nativ/Chat/Sessions`.
2. Load existing `routines.json`.
3. Match routines using `sourceSessionID`.
4. Attach valid routines to their sessions.
5. Convert runs to `sessionID` ownership.
6. Mark or remove routines whose source chat is missing.
7. Write the new session records successfully.
8. Only then archive/remove the old files.
9. Reconcile launch agents against the new session store.

Existing behavior should remain:

- deleting a routine from the editor keeps the chat
- deleting a chat deletes its routine
- disabling a routine keeps both chat and configuration
- deleting a routine cancels queued/active work

## Phased implementation plan

### Phase 1: Correct lifecycle behavior

- Add `SessionStore` as a façade over current stores.
- Route every chat deletion path through it.
- Fix bulk deletion.
- Add orphan cleanup.
- Prevent post-delete run/chat resurrection.
- Add cancellation state.

### Phase 2: Move ownership into sessions

- Add optional routine configuration to `ChatSession`/`SessionRecord`.
- Remove runtime dependence on `sourceSessionID`.
- Migrate old `routines.json`.

### Phase 3: Fix execution lifecycle

- Add queued and active cancellation.
- Make runners use session IDs, not copied routine values.
- Add `.cancelled` status.
- Finalize timeout/crash states.
- Prevent completion notifications for deleted routines.

### Phase 4: Fix persistence

- Move chat data from Caches to Application Support.
- Add repository-level atomic writes and interprocess locking.
- Reconcile stale data and launch agents at startup.

### Phase 5: Test the full lifecycle

Add tests covering:

- normal delete
- bulk delete
- editor routine delete
- delete while queued
- delete while running
- completion after deletion
- missing source session
- startup recovery
- launch-agent reconciliation
- migration
- concurrent run persistence

## Recommendation

Approve the **aggregate-root design**, not a literal “everything in one class” design:

```text
SessionStore
 ├── owns SessionRecord relationship
 ├── owns lifecycle invariants
 └── coordinates deletion/reconciliation

SessionRepository
RoutineScheduler
RoutineRunCoordinator
RoutineLaunchAgentManager
```

This fixes the current issue while preventing the same class of bug from recurring in bulk operations, API execution, launchd runs, crashes, and future UI paths.

No nativ code has been modified yet.