# NativTrace

Records what a model was actually exposed to, so a call can be reconstructed
long after it ran.

A trace is an append-only log of JSON events. Everything a reader shows — the
chat transcript, the exposure panel, the dashboard's per-call rows — is folded
from that log and can be thrown away and rebuilt. Nothing derived is ever
treated as authoritative.

## Rules

These are the properties the rest of the design depends on. Breaking one is a
format break, not a refactor.

1. **`trace_events` is the source of truth and is append-only.** No code here
   may `UPDATE` a row. The only deletion is retention dropping a whole trace —
   never part of one, because half a conversation cannot be folded into
   anything trustworthy.

2. **Derived tables are rebuildable and say so.** `trace_index` and
   `trace_models` exist to make listing fast. `TraceStore.rebuildIndex()` must
   always reconstruct them from `trace_events` alone. Never read a fact from
   them that is not derivable from the events.

3. **Readers tolerate what they do not understand.** `TraceEventKind` and the
   `*Origin` types are open string-backed types, not closed enums, and payloads
   are `TraceJSON` rather than fixed structs. A trace written by a newer build
   decodes here: unknown kinds render opaquely, unknown fields survive read,
   re-encode, and export. A `TracePayloadView` returning `nil` means "not mine",
   never "crash". A payload that cannot be decoded at all still yields its
   event, carrying `TraceStore.unreadablePayloadKey`.

4. **Compression is storage, not format.** `payload_encoding` is a detail of the
   database. An exported trace is always plain JSON, so a future codec can be
   added without invalidating anything already exported.

5. **Migrations are append-only and named.** Once a migration name has shipped
   it is never renamed, reordered, or edited — databases in the field record it
   as applied and will skip it forever.

6. **The core imports Foundation, SQLite3, Compression, and CryptoKit.** No
   SwiftUI, no AppKit, no app types. That is what lets a test harness, a CLI, or
   a separate viewer read traces without linking the app, and it is why the
   suite runs without building Nativ. `scripts/dump_trace.py` exercises the
   property: it reads a live trace in another language with no app involved.

7. **Vocabulary crossing the producer/reducer seam is typed, not stringly.**
   `TraceEventKind` and the `*Origin` types are open because they name things a
   future build may add. Payload *values* — a turn's status, a consent decision
   — are closed enums, because both sides must agree on them and a `String`
   there drifted immediately: the reducer once handled decisions no producer
   emitted, and gated a state transition on one of them.

8. **Provenance is recorded at composition time, never parsed back out.** Nativ
   assembles the system prompt itself, so `PromptSection` carries a real origin
   from the code that appended it. Recovering structure by string-matching a
   flattened prompt is the failure mode this design exists to avoid.

9. **Bodies are referenced, not repeated.** A tool loop re-sends the whole
   conversation every round; storing it each time makes a turn quadratic in its
   own length. `TraceMessageRef` names the message and hashes its content;
   `TraceExposureIndex` resolves it against events already in the trace, and
   `contentHash` is what lets a reader prove it resolved the right body after an
   edit or a branch.

10. **Sequence allocation and the append that consumes it are one call.**
   `TraceStore.record` does both. An API that hands out a sequence number and
   trusts the caller to use it invites two writers to interleave, and the gap is
   silent.

11. **Order survives all the way to disk.** Producers serialise their own writes
    and `TraceRecorder` awaits the store rather than spawning a task per event.
    Detached tasks reach an actor in scheduler order, which is how a tool result
    ends up recorded before the call it answers. Payloads are encoded on the
    consumer for the same reason the queue exists: every producer runs on the
    main actor, and a tool output can be hundreds of kilobytes.

## Layout

```
Model/       the format: events, kinds, payloads, exposure types
Store/       SQLite persistence, schema, index, retention
Transcript/  the fold: events → items → display blocks
Capture/     the writer producers talk to
```

Three stages turn a log into something renderable, and each is separable:

```
TraceEvent[]          raw, persisted, append-only
  ↓ TraceReducer      semantic: message | exposure | tool | lifecycle | unknown
TraceItem[]
  ↓ TraceGrouping     presentation: turns, boundaries, collapsed tool runs
TraceDisplayBlock[]
```

`TraceGrouping` makes display choices only. Every input item must appear in
exactly one output block — a grouping rule can never lose a row, and there is a
test that says so.

## Conventions

- One file per concept; split before a file reaches ~400 lines. `TraceStore`
  delegates index maintenance and retention to `TraceIndex` for that reason,
  not because either is reused elsewhere — and they live together because they
  are one three-table delete, which is what splitting them along the wrong seam
  had obscured.
- SQL runs through `SQLiteConnection.withStatement`, which resets the statement
  on entry and exit and refuses re-entrant use. Statements are cached, so the
  append path does not re-prepare its insert per event.
- Parameters bind in order via `bind(_:)` rather than by index, so adding a
  column cannot silently shift a value into the wrong placeholder.
