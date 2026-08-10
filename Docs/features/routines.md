# Routines

A routine runs a saved prompt on its own — on a schedule or when its endpoint is called — and
appends the result to a chat. Source lives in
[`Sources/Nativ/Features/Routines/`](../../Sources/Nativ/Features/Routines/).

## Model

A routine belongs to one chat. Each run appends the prompt and the model's reply as new turns in
that chat (`sourceSessionID`), so the routine's history reads as an ongoing conversation rather than
a series of disconnected outputs. Routine chats are marked in the sidebar.

A routine records its name, instructions (the prompt), the model to run, its trigger, an optional
[Kit](../extending/kits.md) for added capabilities (`kitID`), a finish-notification preference, and
an enabled flag — see [`Routine`](../../Sources/Nativ/Features/Routines/Routine.swift).

## Creating a routine

- **New routine** from the sidebar creation menu opens the editor and, on save, creates the
  routine's chat.
- **Make recurring** from an existing chat prefills a routine from that chat's last prompt, model,
  and title.

Removing a routine chat cancels its routine; editing a routine offers removal that keeps the chat.

## Triggers

| Trigger (`triggerKind`) | Runs when |
|---|---|
| `schedule` | A configured time and set of weekdays is reached. |
| `api` | The routine's endpoint receives a request: `POST /v1/routines/{id}/run`. |

Scheduled runs are delivered by a per-routine launchd agent that launches a headless run; a
disabled routine does not run. A finished run can post a completion notification when enabled.

## Execution

When a run fires, the server is started if needed and awaited for readiness, the prompt (with the
routine's Kit instructions, if any) is sent to the routine's model, and the reply is appended to the
routine's chat and persisted. Run status and a short result summary are recorded per run.
