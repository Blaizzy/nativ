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

1. **`trace_events` is the source of truth and is append-only.** No code in this
   framework may `UPDATE` a row. The only deletion is retention dropping a whole
   trace. If a fact is worth showing, it is worth writing as an event.

2. **Derived tables are rebuildable and say so.** `trace_index` exists to make
   listing fast. `TraceStore.rebuildIndex()` must always be able to reconstruct
   it from `trace_events` alone. Never read a fact from the index that is not
   also derivable from the events.

3. **Readers tolerate what they do not understand.** `TraceEventKind` and the
   `*Origin` types are open string-backed types, not closed enums, and payloads
   are `TraceJSON` rather than fixed Swift structs. A trace written by a newer
   build decodes here: unknown kinds render opaquely, unknown payload fields
   survive read, re-encode, and export. A `TracePayloadView` returning `nil`
   means "not mine", never "crash".

4. **Compression is storage, not format.** `payload_encoding` is an
   implementation detail of the database. An exported trace is always plain
   JSON. A future codec can be added without invalidating anything already
   exported.

5. **Migrations are append-only and named.** Once a migration name has shipped
   it is never renamed, reordered, or edited — databases in the field record it
   as applied and will skip it forever. Add a new one instead.

6. **The core imports Foundation and SQLite3, nothing else.** No SwiftUI, no
   AppKit, no app types. That is what lets a test harness, a CLI, or a separate
   viewer read traces without linking the app.

7. **Provenance is recorded at composition time, never parsed back out.** Nativ
   assembles the system prompt itself, so `PromptSection` carries a real origin
   from the code that appended it. Recovering structure by string-matching a
   flattened prompt is the failure mode this design exists to avoid.

8. **Bodies are referenced, not repeated.** A tool loop re-sends the whole
   conversation every round; storing it each time makes a turn quadratic in its
   own length. `TraceMessageRef` names the message and hashes its content, and
   the reader resolves it against events already in the trace. `contentHash`
   is what lets the reader prove it resolved the right body after an edit or a
   branch.

## Layout

```
Model/     the format: events, kinds, payloads, exposure types
Store/     SQLite persistence, schema, migrations, retention
Transcript/ the fold: events → items → display blocks
Capture/   producers that turn app activity into events
```

## Files

- `Model/TraceJSON.swift` — lossless JSON value; canonical form is what gets
  hashed and stored.
- `Model/TraceEvent.swift` — the envelope, plus `TracePayloadView` for typed
  reads.
- `Model/TraceEventKind.swift` — the event taxonomy. Values are on-disk format;
  never rename or reuse one.
- `Model/TraceExposure.swift` — `PromptSection`, `ToolDescriptor`,
  `SamplingParameters`.
- `Store/TraceStore.swift` — the actor that owns the database.
- `Store/TraceSchema.swift` — base schema and the migration list.
