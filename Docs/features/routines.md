# Scheduled

A scheduled task runs a saved prompt on its own schedule and appends the result to a chat. Source lives in
[`Sources/Nativ/Features/Routines/`](../../Sources/Nativ/Features/Routines/).

## Model

A scheduled task belongs to one chat. Each run appends the prompt, tool activity, and the model's
reply as new turns in that chat (`sourceSessionID`). Scheduled chats are marked in the sidebar.

A scheduled task records its name, instructions, schedule, capability selections,
finish-notification preference, and enabled flag. Capabilities can reference a
[Kit](../extending/kits.md), an enabled MCP server, one tool, or one skill. Existing records with the
legacy `kitID` field migrate to a kit capability when loaded.

## Creating a scheduled task

- **New scheduled task** from the sidebar creation menu opens the editor and, on save, creates its
  chat. Selecting a kit enables the kit's constituent integrations; individual selections remain
  narrow allowlists for that task.

Removing a scheduled chat cancels its task; editing the task offers removal that keeps the chat.

## Schedule

Runs are delivered at the configured time and weekdays by a per-task launchd agent that launches a
headless run. A disabled task does not run. Completion notifications are opt-in per task and are
delivered only after the user grants notification access in Nativ or System Settings.

## Capabilities

- **Kits** are convenience bundles. Selecting one enables its integrations; at runtime it expands
  to the kit skills and any constituent MCP servers that remain enabled.
- **MCP servers** grant all enabled tools exposed by one connected server.
- **Tools** grant one built-in, custom, or MCP operation.
- **Skills** add selected reusable instructions to the system prompt.

Global switches in Extensions remain authoritative: a disabled or removed server or tool is not
made available to a scheduled task. The selected model must support tool calling to use tools.

## Execution

When a run fires, the model server is started if needed and awaited for readiness. Selected MCP
servers are connected, capability references are resolved, and only the resulting tools and skills
are sent to the model. Tool calls run for at most four advertised rounds; one final untooled round
lets the model synthesize the result. The prompt, tool activity, and final reply are appended to the
scheduled chat. Run status and a short result summary are recorded per run.
