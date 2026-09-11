# Extension workspaces

Music Lab will be an extension-owned workspace, like Audio. This first layer
lets a package contribute a native page with tabs, persistent controls, and
commands with progress and cancellation. It contains no Music Lab-specific
Swift code and requires no model-server changes.

## Contract

Workspace packages use manifest schema 2 and reference `Dashboard.json`.
Schema 1 text-workflow packages continue to work. Older hosts reject schema 2
rather than accepting UI they cannot render. A workspace contributes exactly
one sidebar destination; its dashboard owns the tabs within that page.
`Workflow.json` is optional for a workspace without commands.

A dashboard declares `schemaVersion`, `title`, `storage`, and `tabs`. Each tab
has a stable `id`, `title`, and `sections`. Each section has `id`, `title`, and
`components`. Supported components are text, textField, toggle, picker, and
button. A component uses `text` for literal content, `storageKey` for a direct
binding, or `commandID` for a declared command. Pickers declare their options.
No expressions, scripts, paths, or recursive interpolation are evaluated.

Storage declares named fields with `type` (text, number, boolean) and
`defaultValue`. Controls and workflows share that state. Values are isolated
by extension ID, bounded, written atomically outside the installed package,
and retained when disabled, updated, or uninstalled. Reinstalling the same ID
restores compatible fields. Incompatible or removed fields use new defaults;
corrupt state is reported rather than silently overwritten.

`storage.read` takes a literal `key` and produces a typed `value`.
`storage.write` takes a literal `key` and a typed `value`; an exact binding such
as `{{read.value}}` preserves its type. Keys must be declared in the dashboard,
and storage use requires `storage.namespaced`. Model prompt interpolation may
format scalar outputs but never evaluates bindings inside a stored value.

Each schema 2 command trigger can select an ordered `steps` list, so different
buttons execute different actions within the same package. Bindings and
selection prerequisites are checked independently for each command. Omitting
`steps` preserves the schema 1 behavior of executing the full workflow.

An enabled workspace owns one active command at a time. Progress reports
completed steps, not estimated model progress. Navigation does not stop a job;
Cancel, disabling, removal, package replacement, and permission changes do.
A cancelled task cannot commit later storage writes or overwrite a newer run's
status. Work does not resume automatically after application termination.

## Next layers for Music Lab

This is the workspace foundation, not a music engine. Typed media handles,
user-selected file import, audio playback/transport, media collections, and
capability-based music-model operations still need explicit host contracts.
Those operations belong behind the workflow services boundary; packages must
not receive arbitrary filesystem paths, shell execution, or network access.

The private registry remains pinned to its existing contract until the new
host is reviewed and its validator can be pinned to a published commit.

## Local validation and handoff

The sample is `Examples/ExtensionWorkspace/com.example.workspace.nativextension`.
Install it through Extensions → Extensions → Installed → Install from Folder,
enable Session Workspace, and use its sidebar page. Save copies the draft into
the saved note; Clear resets only the saved note. Settings exercises number,
boolean, and picker values without requiring a model or macOS Accessibility.

Validation on September 9, 2026:

- XcodeGen and the local Debug app build succeeded.
- 74 focused SDK and runtime tests passed, including command routing, retained
  state, isolation, malformed packages, symlink rejection, permission changes,
  cancellation, and late results arriving after a replacement run.
- Live package installation and enablement succeeded; its sidebar entry and
  separate command buttons appeared.
- The computer-use connection failed while opening the page. Editing controls,
  navigation, visual layout, and persistence across an actual app restart remain
  manual QA items. Automated persistence and lifecycle checks passed.

The focused test run used a temporary XcodeGen project containing the real SDK
and runtime sources and the SDK, workflow-runner, and workspace-runtime tests.
It does not establish that the full Nativ test target passes; that target has a
pre-existing SystemMonitorIdentityTests module import issue.
