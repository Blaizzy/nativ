# Development Handoff

## Checkout

- Repository: `Blaizzy/nativ`
- Path: `.nativ-dev`
- Branch: `feat/session-routine-lifecycle`
- Base commit: `0ccf774`
- This branch contains the local routine/session lifecycle implementation and its handoff documentation.

## Design

`CHANGES.md` contains the approved lifecycle audit and proposed architecture verbatim.

## Local implementation started

Phase 1 changes currently in the working tree:

- Bulk chat deletion now removes its associated routine.
- `RoutineRunStatus.cancelled` was added.
- `RoutineStore` now supports injected persistence for tests.
- Routine deletion notifies the runtime so active/queued runs can be cancelled.
- `RoutineRunner` queues routine IDs instead of copied routine values.
- `RoutineRunner.cancel(routineID:)` cancels queued and active work.
- Runner execution revalidates routine and source-session existence.
- Deleted routines cannot have run records resurrected by late completion.
- Missing source sessions no longer cause a replacement chat to be created.
- App startup reconciles routines against persisted chat-session IDs.
- Cancelled routine runs do not generate completion notifications.
- Added `Tests/NativTests/RoutineLifecycleTests.swift`.
- Added routine source files and the new test file to the test target in `project.yml`.

## Validation

- `swiftc -parse` passed for the modified Swift files and new tests.
- `git diff --check` passed.
- Full Xcode build/test was attempted but is blocked on this host because `xcodebuild` resolves to CommandLineTools rather than a full Xcode installation.

## Important follow-up work

1. Typecheck/build with full Xcode.
2. Review Swift 6.3 actor-isolation diagnostics, especially `RoutineStore.Persistence` and `RoutineRunner` task ownership.
3. Add a real `SessionStore` aggregate boundary rather than leaving UI paths coupled directly to `RoutineStore` and `ChatViewModel`.
4. Add cross-process cancellation for headless launch-agent runs.
5. Add startup recovery for stale `.running` records and timeout finalization.
6. Move chat persistence from Caches to Application Support with migration.
7. Add repository locking/atomic coordination for GUI and headless processes.
8. Add launch-agent manager abstraction and fake launchd tests.
9. Keep generated Xcode project changes limited to the routine sources and lifecycle test when regenerating the project.
