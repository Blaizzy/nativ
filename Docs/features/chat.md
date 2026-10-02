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

## Sessions and folders

Each conversation is one session, persisted as a JSON file under
`~/Library/Application Support/Nativ/` and loaded on launch
([`ChatSessionStore`](../../Sources/Nativ/Features/Chat/ChatSessionStore.swift)). A session
carries its title, messages, timestamps, pin state, and an optional folder assignment.

- Sessions can be renamed, pinned, and deleted from the sidebar.
- Folders (`ChatFolder`) group sessions in the sidebar; folder membership is stored on the
  session (`folderID`) and the folder list persists alongside sessions.
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
messages or opening work-pane items, choose **Local > Worktree…** in the project bar to
create a separate Git checkout and a `nativ/<chat-id>` branch for that chat. The project
must be a Git repository with at least one commit. Worktree creation starts at its current
commit; it leaves uncommitted files and the project's current branch unchanged.

File read/write/search tools, project MCP scope, and new terminals use the chat's checkout.
Projects rooted in a repository subfolder keep that relative folder in the checkout.
The worktree is the default working directory, not a sandbox for shell commands. Work-pane
documents retain their separate per-chat storage.

The environment menu shows the created branch and provides **Copy branch name**,
**Copy folder path**, and **Show in Finder**. Checkouts live under the app profile's
`Chat/Worktrees/<chat-id>` folder. Each chat keeps this association across launches;
an unavailable checkout disables project tools instead of redirecting them to Local.
Failed setup remains attached to the chat and can be retried from the environment menu.

Empty worktree chats are retained. Closing a chat keeps its checkout and branch. Deleting
it saves and verifies a self-contained Git bundle before removing its managed checkout and
branch. Snapshots preserve committed history, the index, unstaged edits, and non-ignored new
files. Ignored files require an additional confirmation listing excluded paths; cancel keeps
the chat and its work. Submodules and nested Git repositories block cleanup because their
contents cannot be fully captured by the parent repository's snapshot. Cleanup
refuses changed checkout registrations, branches in use elsewhere, and locked worktrees;
on failure the chat remains available for retry. The local project folder is never removed.
Bulk deletion and **Remove project > Delete Chats** use the same cleanup; **Keep Chats**
preserves their worktrees. Active worktree chats and terminal commands must be stopped first.

**Settings > Projects > Recently deleted worktrees** lists snapshots, independently of the
deleted chat. **Restore** recreates the files and staged/unstaged changes on a new managed
branch in a new chat, using the original repository, which must still be available at its
original location. The old conversation is not restored. Snapshots are kept under
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
  chat storage at `Files/<chat-id>/<item-id>/<filename>`, so duplicate names do not
  overwrite each other. Pane and agent edits save to these files. Edits made in an
  external editor or terminal are picked up by **Refresh files**, when returning
  to the app, or before the next agent work action; conflicting edits are rejected.
  Agent `chat_work` results include the same `file_path`. Remote website and terminal
  tabs are not source files.
- **Websites:** switch generated HTML between source and an interactive preview,
  or browse an HTTP(S) URL, including a local development server. Remote pages have
  back, forward, reload, and address controls. Cookies and website storage use a
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
  into a separate, output-only **Agent terminal** tab. Each native `terminal` command
  still runs in its own process and uses the existing command approval flow.
  Agents can also run commands in an existing interactive tab with `chat_work.run`,
  including in standalone chats. Each command shows its target and arguments for
  approval and passes the terminal command safety checks. Shell input or process
  changes invalidate pending approval. User zsh startup files still load normally.
- **Translation:** the Translate button opens the native macOS translation popover
  for selected source or browser text, or the document/page's prose. Select the target
  language in the popover; macOS may offer to download a language. Selected Markdown
  preview text also has a **Translate…** context-menu action. Translation does not
  overwrite the original content.
- **Collaboration:** use the discussion button to add feedback to the chat draft,
  including selected source text and the item's revision. Nothing is sent until
  the user sends the draft.
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
`inspect`, `navigate`, `back`, `forward`, `reload`, `click`, and `type` operate on
the same browser instance displayed to the user and return a fresh page snapshot.
Browser actions can omit `id` to use the selected remote website; `click` and `type`
instead resolve the tab from the supplied element ID, even after selecting another
tab. The resolved target is shown and fixed before consent. The item list
includes website URLs so agents can distinguish renamed or navigated tabs.
Browser element IDs expire after
the next inspection or action, and changed inputs are rejected. All `chat_work`
calls use the existing consent UI, showing the action arguments before execution.

This version supports up to 24 items per chat and 256 KB of text per item. Office
documents and PDFs are not editable in this pane. Code-file previews do not
execute code; use a terminal for local commands.
Browser inspection covers the main document's DOM, not canvas controls, shadow
roots, or embedded frames. Password and file inputs require direct user interaction.
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
grouping by chat. Rendered files are cached under Application Support.

**Smart search** ranks artifacts semantically using an on-device embedding model. It activates
only after that model is installed; until then, search falls back to plain text matching over
artifact metadata.
