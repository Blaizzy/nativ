# Chat

Chat is the primary workspace for conversing with a locally served model. It streams
responses, renders reasoning output, accepts image attachments for vision models, and
exposes host capabilities to the model as consent-gated tools. Source lives in
[`Sources/Nativ/Features/Chat/`](../../Sources/Nativ/Features/Chat/).

## Conversations

- Responses stream token by token. Reasoning ("thinking") output from models that emit
  it renders in a collapsible panel separate from the final answer.
- Per-response metrics (time to first token, decode speed, token counts) are recorded and
  surfaced from the analytics store.
- Hover over a completed response and select **Read aloud** beside **Copy** to send
  its text to the server's `/v1/audio/speech` endpoint and play the returned audio on
  your Mac. Choose a text-to-speech model in **Models** first. The control shows
  generation progress and becomes **Stop reading aloud** during playback;
  selecting another response or leaving the chat stops the current audio.
- During prefill, a “Reading prompt” status pill with a circular progress ring and
  percentage appears next to the model's name above the active assistant response,
  including responses that use tools. Hover over the pill for processed/total tokens.
  This shared server activity includes requests from other windows and API clients.
  Progress starts at 0%, advances with processed tokens
  (including cached tokens), briefly holds at 100%, then fades out. Animations respect
  Reduce Motion. Runtimes that report only prefill start/end advance directly from 0% to
  100% when prefill completes.
- Image attachments accompany a user message for vision-capable models.
- The active model is chosen from the model picker; only language-capable models are
  selectable as the conversation model.

## Conversation compaction

**Auto compact** is enabled by default in Model Configuration. With
a compaction-capable mlx-vlm server, chat uses `/v1/responses` and asks the server
to summarize older context before generation. Use the slider below **Auto compact**
under **Model Context** to choose when it triggers; hover the info icon for details.
Its scale runs from 1–100%, with
the handle limited to 20–90% (default 75%). Changes apply to
the next message without restarting the server. With a 10,000-token context window,
50% triggers at 5,000 input tokens. **Max output** is an upper bound on generated
tokens; it does not reserve input space or change the compaction threshold.
The server counts the rendered input, compacts older history when the threshold
is reached, then limits generation to the smaller of **Max output** and the
remaining context capacity. The saved setting stays unchanged. Summary generation
has its own server-managed budget. Compaction runs before each generation request,
including subsequent tool rounds, rather than during a streaming response.
If a response reaches the context limit, it stops with a length finish reason;
the next request can compact the accumulated history.
If neither server nor local model metadata gives a limit, Nativ uses an
8,192-token fallback.

Chat shows compaction progress and a completed notice with server-measured input
token counts when available. The completed notice is saved with the transcript;
an interrupted progress indicator is not restored after relaunch.

The full transcript stays visible and editable. Encrypted compaction state is saved
separately with the session and replayed with subsequent messages, including tool
results. Editing covered messages or changing the model, server, or instructions
rebuilds the request from the transcript. Failed or cancelled requests do not replace
saved compaction state. **Prefix Caching** is enabled by default in Model Configuration to reuse
the new compacted prefix. Compaction also works with caching disabled.

PDF and other document excerpts are sent as current source context, separately
from the saved conversation. Selecting different passages or fitting them to the
remaining space preserves the summary; editing a covered message or replacing
its attachment still rebuilds the history. Document fitting counts the summary
and uncovered messages rather than the full pre-compaction transcript.

Compaction requires a server that supports the Responses compaction API and
budgets output from actual input usage. The bundled requirements pin the server
revision from [mlx-vlm PR #2458](https://github.com/Blaizzy/mlx-vlm/pull/2458).
External servers need that change too. To test a different checkout containing
the fix, override the bundled source:

```sh
MLX_VLM_SOURCE_PATH=/path/to/mlx-vlm-compaction make xcode-build
```

Keep the server's compaction encryption key across restarts. A changed or missing
key makes existing capsules unusable; the transcript is still preserved. Disabling
compaction sends the full transcript through Chat Completions.

## Sessions

Each conversation is one session, persisted as a JSON file under
`~/Library/Application Support/Nativ/` and loaded on launch
([`ChatSessionStore`](../../Sources/Nativ/Features/Chat/ChatSessionStore.swift)). A session
carries its title, messages, timestamps, pin state, and optional project membership.

- Sessions can be renamed, pinned, and deleted from the sidebar.
- Chats previously assigned to folders appear automatically in **Sessions**. Individually
  pinned chats remain in **Pinned**, and project chats remain with their projects.
- Older session files load with their obsolete `folderID` ignored; the next save removes
  that field. Old `folders.json` files are left unused, so missing or damaged folder
  metadata cannot block chat loading or migration from the legacy cache.
- Empty, redundant sessions are pruned automatically.

### Import and export

The action menu for a chat exports a versioned JSON file containing its messages,
attachments, model repository ID, system prompt, and basic session metadata. Use the import
button above the sidebar to add one of these files as a new local session.

Imported tool calls are kept as history and are never run automatically. Nativ offers to
switch to the original model when it is installed and links to Models when it is missing.
Users can instead continue with any downloaded language model. A chat remains read-only when
its recorded token count exceeds the selected model's context window.

## Project chat environments

New project chats start in **Local**, using the project's existing folder. Before sending
messages or opening work-pane items, check **Worktree** above the composer to reserve a separate
Git checkout directly, without a confirmation popup. Uncheck it before the first message to
return to the local project folder. Once the chat starts or a checkout exists, the choice is locked.
The project must be a Git repository with at least one commit. On the first message, before
the agent starts, Nativ fetches the remote's
default branch, asks the selected model for a descriptive branch name based on that message,
and creates the checkout on `nativ/<name>` without a chat ID or numeric suffix. If naming fails,
returns an invalid name, or names an existing local branch, Nativ picks two random words such
as `nativ/quiet-cedar`, excluding existing local branches. It prefers `origin`, otherwise the current
branch's remote or the sole configured remote. Repositories without a remote use their local
commit. The project's current branch and uncommitted files stay unchanged.

A setup card above the composer shows **Sync remote**, **Name branch**, and **Create worktree**,
with a spinner on the active step and circular checkmarks on completed steps. The completed
card closes automatically after one second. Sync or checkout
failures stop the request before the agent can act; send another message to retry using the
original first prompt. Existing worktrees are never synced or renamed automatically, and an
interrupted checkout resumes its saved branch and commit.

File read/write/search tools, project MCP scope, and new terminals use the chat's checkout.
Projects rooted in a repository subfolder keep that relative folder in the checkout.
The worktree is the default working directory, not a sandbox for shell commands. Work-pane
documents, code, and generated websites live inside its project folder at
`Nativ Files/<item-id>/<filename>`. Existing worktree chats migrate their side-pane files
there, preserving external edits and keeping legacy copies for recovery. Missing checkouts
never fall back to the local project or chat storage.

Empty project chats show project, environment, and branch controls directly above the composer.
Once the conversation starts, the **Pinned summary** toolbar toggle opens these controls,
the checkout path, project-tool status, and file count without a full-width header.
The project menu beside the branch name provides **Copy branch name**,
**Copy folder path**, and **Show in Finder**. Checkouts live under the app profile's
`Chat/Worktrees/<chat-id>` folder. Each chat keeps this association across launches;
an unavailable checkout disables project tools instead of redirecting them to Local.
Pending or failed setup remains attached to the chat across launches and resumes when a message is sent.
Agents can create, switch, or rename branches through the approved terminal. Git is the
source of truth: the visible controls refresh every two seconds and agent context reads HEAD
on every model request, including follow-ups in the same turn. Detached HEAD shows the commit
instead of a stale branch, with **Copy commit ID** in the menu.

Empty worktree chats are retained. Closing a chat keeps its checkout and branch. Deleting
it saves and verifies a self-contained Git bundle of the current HEAD before removing its
managed checkout, including after a branch switch or detached checkout. Only the original
Nativ-created branch is eligible for deletion, and only when its history is included in the
snapshot and it is unused elsewhere. Other branches, including renamed and user-created
branches, are preserved. Snapshots preserve committed history, the index, unstaged edits, and non-ignored new
files. Ignored files require an additional confirmation listing excluded paths; cancel keeps
the chat and its work. Submodules and nested Git repositories block cleanup because their
contents cannot be fully captured by the parent repository's snapshot. Cleanup
refuses changed checkout registrations and locked worktrees;
on failure the chat remains available for retry. The local project folder is never removed.
Bulk deletion and **Remove project > Delete Chats** use the same cleanup; **Keep Chats**
preserves their worktrees. Active worktree chats and terminal commands must be stopped first.

**Settings > Projects > Recently deleted worktrees** lists snapshots, independently of the
deleted chat. **Restore** recreates the files and staged/unstaged changes on a new managed
branch in a new chat, using the original repository, which must still be available at its
original location. Saved side-pane file entries are reopened against the restored checkout;
ignored or externally deleted files are not recreated. The old conversation is not restored. Snapshots are kept under
`Chat/DeletedWorktrees/<snapshot-id>` until explicitly removed with **Delete permanently**;
that action requires confirmation and never deletes restored checkouts. An interrupted cleanup
may leave a snapshot alongside its original chat, so the saved work remains recoverable.

Git commit and merge remain terminal operations. Conversation forking is unavailable for
worktree chats in this first version, to avoid silently sharing their checkout with another
chat; create a new project chat for another worktree instead.

## Multiple windows

Choose **File > New Window** or press Command + Shift + N to open another workspace.
Each window keeps its own navigation, chat, draft, and generation state while sharing the
inference server, loaded models, and settings. A chat can generate in only one window at a
time, and model selection is unavailable while any window is generating.

## Work pane

Select **Work pane** (⌘⇧B) to open a resizable workspace beside the conversation.
The **+** button opens a new-tab page without closing existing tabs. **Tools**
creates terminals, documents, and HTML pages; **Suggested** and
**Recents** reopen saved work. The rounded address bar accepts HTTP(S) URLs, bare
hostnames, local development addresses, or search terms (searched with Google).
The expand control switches between split and full view. Model configuration and
the work pane share the right side of chat.

- **Documents and code:** use the eye and code icons to switch between preview and
  source. **Copy** copies the full source; its menu also offers plain text for Markdown
  and the file name. You can also export a file. Markdown previews render math and
  resolve newly imported documents' relative images against the original file location. Text imports are copies;
  editing them does not modify the original.
- **Files:** browse the documents, code, and generated HTML saved in this chat,
  including closed tabs. **Search files** filters by filename or extension.
  Selecting a file reopens its existing side-pane tab.
  The **Files options** menu in the header offers
  **Import**, **Refresh files**, **Copy folder path**, and **Show folder in Finder**.
  Right-click a file for **Rename…**, **Copy file path**, **Show in Finder**, and **Delete**.
  Delete moves the saved file to macOS Trash and removes its tab and entry from this chat;
  imported originals are kept. Recover a deleted file from Trash and import it to use it again.
  Renaming updates
  the existing tab and the file on disk while preserving its contents. You can also
  rename from a tab's context menu or the file's toolbar menu. Sources live under the app's
  chat storage at `Files/<chat-id>/<item-id>/<filename>` for Local chats, or in the
  checkout's `Nativ Files/<item-id>/<filename>` for Worktree chats, so duplicate names do not
  overwrite each other. Pane and agent edits save to these files. Edits made in an
  external editor or terminal are picked up by **Refresh files**, when returning
  to the app, or before the next agent work action; conflicting edits are rejected.
  Agent `chat_work` results include the same `file_path`. Remote website and terminal
  tabs are not source files.
- **Websites:** switch generated HTML between source and an interactive preview,
  or browse an HTTP(S) URL, including a local development server. Remote pages have
  back, forward, reload, and address controls. Agents can search Google in the same
  tab with `chat_work` (`action: search`, `query: ...`) without a search API key.
  Search requests start with results instead of guessed domains. Connection failures
  and HTTP errors such as 404 include the failed URL, tab ID, and guidance to search
  the original subject; the previous page is never returned as the failed destination.
  Cookies and website storage use a
  persistent profile shared across tabs, chats, and windows, so website sign-ins
  survive closing tabs and restarting the app, until the website expires them.
  This profile is separate from the user's regular browser; Nativ Preview also
  has its own profile. The page's **⋮ → Clear website data…** action asks for
  confirmation, then removes this app profile's cookies, website storage, and
  caches and reloads open pages. Chats and documents are kept. Existing sign-ins
  from older builds' temporary tabs require signing in once after upgrading.
- **Terminal:** choose **+ → Terminal** for an interactive zsh shell in the chat's
  project folder, or your home folder. Each terminal retains its process, working
  directory, and environment while switching tabs or chats. Closing the tab stops
  the shell and saves a bounded, redacted output snapshot; reopening it or
  restarting the app starts a fresh shell. Approved agent `terminal` commands stream
  into a separate, output-only **Agent terminal** tab without changing the selected
  tab or opening a hidden work pane. Each native `terminal` command
  still runs in its own process and uses the existing command approval flow.
  After two seconds, a command that is still running returns `running: true` and
  a `terminal_id`, allowing the agent to continue. It can read output with
  `chat_work.read` or stop the command with `chat_work.interrupt`. Servers and
  watchers should use `terminal` with `background: true`; they stay alive until
  stopped or the terminal closes. Other commands retain their execution timeout
  (180 seconds by default). Running does not guarantee that a server is ready.
  New commands use another agent terminal while an existing command is running.
  Quitting Nativ stops managed commands, interactive shells, and their foreground
  child processes before the app exits. Closing a window does not quit Nativ.
  Agents can also run commands in an existing interactive tab with `chat_work.run`,
  including in standalone chats. Each command shows its target and arguments for
  approval and passes the terminal command safety checks. Shell input or process
  changes invalidate pending approval. User zsh startup files still load normally.
- **Translation:** the Translate button opens the native macOS translation popover
  for selected source or browser text, or the document/page's prose. Select the target
  language in the popover; macOS may offer to download a language. Selected Markdown
  in chat messages also has a **Translate…** context-menu action. Translation does not
  overwrite the original content.
- **Collaboration:** **Add to chat** adds an annotation directly to the composer,
  including the page or file, selected source text, and the item's revision. **Annotate**
  adds a selected webpage element the same way. Files also offer **Add to chat** in
  their right-click menu. To reference a section of a document, select its text in
  Preview or Source. The selection menu contains only **Add to chat** and **Edit**.
  **Add to chat** focuses the composer so you can type your comment; nothing is sent
  until you send the draft. **Edit** opens a compact input below the selection;
  the arrow button (Return or Command-Return) sends the instruction and selected passage
  directly to the agent to edit that file. Escape or clicking outside dismisses the input. Both actions preserve existing draft text and attachments.
- **Persistence:** items, open tabs, selection, and pane visibility are saved with
  the session. Closing a tab preserves its contents under **+ → Recents**.
  Work-only sessions are retained even if no messages have been sent.

The native `chat_work` tool lists, reads, creates, opens, and updates these items.
Terminal creation accepts a title with `kind: "terminal"`. For an existing terminal,
`run` takes its `id` and a `command`, preserving the shell's working directory and
environment. An omitted ID uses only the selected terminal. `read` and `inspect`
return current output, working directory, running state, readiness, and exit code;
`interrupt` sends Ctrl-C. `run` waits up to `timeout` seconds (1–30, default 10), then
returns the current state without stopping a longer command. Read again to follow
progress. A busy terminal or a partially typed command must be finished or
interrupted before another agent command can run. Browser click/type actions and
editing terminal content never execute shell commands.
Updates require the revision returned by `read`; an intervening user edit causes
a conflict instead of being overwritten. If an agent omits an update's ID, the app
uses only its latest read in that chat with the same revision and matching title/kind
when provided. This read receipt is kept in memory, and the target is fixed before
consent. A `.md` or `.markdown` creation can omit `kind`. `open` with a `url` opens a website directly
without requiring a pre-existing item ID; it reuses a saved tab with the same URL.
`navigate` with a `url` changes the selected website, or opens a website if no remote
page is selected. An explicit `id` always targets that tab. Opening or creating a
remote website waits for the page and returns its ID, loaded URL, text, and controls.
`inspect`, `navigate`, `back`, `forward`, `reload`, `click`, `type`, and `upload` operate on
the same browser instance displayed to the user and return a fresh page snapshot.
Browser actions can omit `id` to use the selected remote website; `click`, `type`, and `upload`
instead resolve the tab from the supplied element ID, even after selecting another
tab. The resolved target is shown and fixed before consent. The item list
includes website URLs so agents can distinguish renamed or navigated tabs.
Browser element IDs expire after
the next inspection or action, and changed inputs are rejected. All `chat_work`
calls use the existing consent UI, showing the action arguments before execution.

To attach an original chat file to an email or another website, the model calls
`chat_work` with `action: "attachments"`, then `upload` with `attachment_ids` and
the `element_id` of a file input from the latest page snapshot. The attachment list
survives compaction and includes PDFs, supported Office/text documents, and images
saved in this chat. Original bytes go directly from Nativ's media store to the
website; filenames, MIME types, and IDs go to the model. Excerpts are never used as
replacement files, and the tool does not accept arbitrary filesystem paths.
Inspection includes hidden file inputs, their accepted types, and whether they
allow multiple files. Upload replaces that input's selection, supports up to 20
files totaling 64 MiB per action, and rejects changed inputs, missing attachments,
and files from another chat. Consent shows the original filenames and destination.
`selected_files` confirms the file selection; the model must check the website's
upload status before sending or submitting. Upload itself does not click Send.

This version supports up to 24 items per chat and 256 KB of text per item. Office
documents and PDFs are not editable in this pane. Code-file previews do not
execute code; use a terminal for local commands.
Browser inspection covers the main document's DOM, not canvas controls, shadow
roots, or embedded frames. Password inputs require direct user interaction. File
inputs accept chat attachments through `upload`; folder selection is not supported.
HTML previews run scripts in a sandboxed frame without native host access.

Sources: [`ChatWorkPane`](../../Sources/Nativ/Features/Chat/ChatWorkPane.swift),
[`ChatWorkState`](../../Sources/Nativ/Features/Chat/ChatWorkState.swift), and
[`ChatWorkBrowser`](../../Sources/Nativ/Features/Chat/ChatWorkBrowser.swift).

## Chat tools

A tool-calling model can invoke host capabilities mid-conversation. The registry is
[`ChatToolRegistry`](../../Sources/Nativ/Features/Chat/ChatToolRegistry.swift); available tools:

| Tool | Action |
|---|---|
| Image generate / edit | Produce or edit an image with a compatible image model. |
| Model library | List installed models or switch the active model. |
| Server stats | Report server and request statistics. |
| System monitor | Report live CPU, GPU, and memory readings. |
| Chat work | Create and edit shared work, open tabs, and interact with remote websites in the work pane. |
| File Read | Read bounded text and search contents or filenames in a user-authorized local folder. |
| File Write | Create, overwrite, and patch text files in a user-authorized local folder. |

Tools are advertised to the model only when the active model reports tool-calling support
and the tool is enabled and configured. Tools that change app state or execute custom scripts
use explicit consent gates; bounded read-only tools execute directly. MCP servers contribute
additional tools through the same path — see [Integrations](integrations.md).

### File Read

The built-in `read_file` and `search_files` tools appear as one **File Read** capability and
are local to the Mac running Nativ, including when the model server is remote. They remain
unavailable until the user chooses one authorized folder in **Extensions → Tools → File Read**.

- Relative paths resolve inside that folder. Absolute paths and symlinks are accepted only
  when their canonical target remains inside it.
- Results use one-based `LINE|CONTENT` numbering and bounded line/character pagination.
- Binary and special files, credential stores, private-key paths, and oversized files are
  blocked. High-confidence secret values in otherwise readable text are replaced with
  `<redacted>` without hiding the rest of the file.
- Text-layer PDFs use Nativ's existing PDF extraction.
- `search_files` uses ripgrep with user configuration disabled. Content
  mode accepts ripgrep's default regular-expression syntax and returns line-numbered matches
  with optional context. Files mode accepts a glob, skips hidden and ignored files by default,
  and sorts results by modification date with the newest first.
- Search supports content, matching-file, and per-file count output, plus bounded offset/limit
  pagination. Credential paths are excluded before the search and every returned path is
  revalidated; returned snippets use the same secret-value redaction as `read_file`.
- Identical consecutive searches warn once and are then blocked to stop tool loops. Missing
  search roots are negatively cached briefly, and process time/output limits bound large scans.
- Scheduled routines may use File Read only when the user explicitly selects the capability;
  every run is restricted to a snapshot of the same configured folder.

### File Write

The built-in `write_file` and `patch` operations appear as one **File Write** capability in
**Extensions → Tools** and share one authorized folder and enabled state. `write_file` replaces
an entire UTF-8 text file (creating parent folders as needed), while `patch` supports a
single-file fuzzy replacement and V4A multi-file add, update, delete, and move patches.

- Canonical path checks and descriptor-relative, no-symlink-following I/O keep every mutation
  inside the authorized folder. Sensitive system and key-material paths and binary document
  formats are blocked.
- Protected instruction and credential configuration files require confirmation in the chat.
- Per-path locks serialize mutations. Writes report a SHA-256 verification hash, unified diff,
  staleness warning when applicable, and only newly introduced syntax errors for supported
  formats.
- Content that looks like numbered `read_file` output or an unchanged-read response is rejected
  to prevent accidental tool-output echoing.
- File Write is not offered to scheduled routines because routines have no interactive approval
  surface.

## Image generation

Two paths produce images:

- **Direct** — the **Images** tab drives an image model on its own, with no language model
  involved. Prompt text feeds the image model's own text encoder. Source:
  [`Sources/Nativ/Features/ImageGeneration/`](../../Sources/Nativ/Features/ImageGeneration/).
- **Indirect** — a tool-calling language model calls the image generate/edit tool during a
  chat. The host resolves which image model to run — from the per-session image model, then
  the global `imageGenerationModelID` setting; when neither resolves and more than one
  compatible model is installed, a selection prompt appears; when none is installed, the tool
  returns an actionable "no compatible model" result. Generation runs on the bundled server's
  image endpoint (see [Developer](developer.md)). Model routing lives in
  [`ChatImageModelSelection`](../../Sources/Nativ/Features/Chat/Tools/ChatImageModelSelection.swift).

`imageGeneration` and `imageEditing` are distinct model capabilities; editing requires a
reference image and a model that supports it. See [Models](models.md) for capabilities.

## Artifacts

Every image and document generated or uploaded across chats is collected in the **Artifacts**
gallery ([`Sources/Nativ/Features/Artifacts/`](../../Sources/Nativ/Features/Artifacts/)). It
supports filtering by kind, source (uploaded vs generated), date, and favorites; sorting; and
grouping by chat. All saved work-pane files, including documents, code, and local HTML websites, also appear here,
with export, Reveal in Finder, and Go to Chat. Document cards show a file icon and name;
contents are loaded and rendered only when opened. Markdown is formatted and code is
syntax highlighted, with native previews for other supported formats. They reference the original file
in chat storage or its checkout, without creating another copy. Missing files, remote
web tabs and terminals are excluded because they have no source file. Delete work-pane files from their chat for now;
Artifacts trash and recovery apply to attachments.

**Smart search** ranks artifacts semantically using an on-device embedding model. It activates
only after that model is installed; until then, search falls back to plain text matching over
artifact metadata.


## Tool access modes

The composer’s pill-shaped access button opens a popover with Standard, Medium, and Full access, each with a short description. The selected level has a checkmark; Full access uses a yellow accent. “Learn more” in this popover opens a scrollable comparison table of automatic actions and approval requirements. This table is accessible only through the access popover.
Existing and new chats default to Standard. The selection is saved with the chat
and captured when a request is submitted; changing it affects new requests.

Standard preserves the existing tool confirmation behavior. Medium automatically allows
work-pane reads, creation, edits, browsing/navigation, and terminal interruption. It asks
before browser click/type/upload, protected filesystem writes, model switching, and all
commands/scripts. Ordinary built-in file operations remain automatic. The native filesystem
MCP adapter follows the same protected-path rules. Other MCP servers and custom endpoints
are unclassified and require approval in Medium; tool names and server hints are not proof
that an external operation is read-only.

Full access automatically
allows non-execution tool operations, including browser interactions, work-pane edits,
protected file writes, model switching, and interrupting a terminal command. Native
`terminal`, `chat_work` with `action: run`, and custom script tools still require
confirmation for every execution. Cancellation and denial prevent execution.

Full access does not disable command safety blocks, authorized filesystem roots,
sensitive-path blocks, revision checks, or terminal state validation. MCP servers
continue to supply their own tool capabilities; Nativ does not infer arbitrary MCP
tools’ execution semantics from their names. Scheduled routines retain their existing
policy and do not inherit a chat’s access mode.
