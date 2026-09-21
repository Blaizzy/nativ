# Voice

Voice dictation transcribes speech with a local speech-to-text model and inserts the result at
the cursor in any app. It ships as a capability of the **Audio** first-party extension (installed
and enabled by default; disable, remove, and restore are supported — see
[Extensions](../extending/extensions.md)). Source lives in
[`Sources/Nativ/Features/VoiceCapture/`](../../Sources/Nativ/Features/VoiceCapture/) and
[`Extensions/VoiceDictation/`](../../Extensions/VoiceDictation/).

## Capture flow

A global shortcut starts capture anywhere. On release/stop, the recording is transcribed and the
text is inserted at the current cursor position; the transcript is also placed on the clipboard.

By default, say **“enter”** as the final word to press Return after inserting the text. For example,
“Send me the details enter” inserts “Send me the details” and then presses Return in the target
app. The command is omitted from the inserted text, clipboard, saved transcript, and dictation
history. Capitalization and trailing punctuation (such as “Enter.”) are ignored. Saying only
“enter” presses Return without pasting text or changing the clipboard. “Enter” elsewhere in a
dictation remains ordinary text. This also applies when retrying a dictation.

In **Audio → Shortcuts → Spoken Return**, turn the command on or off and change its **Trigger
word or phrase** (for example, “send it”). Only the configured trigger at the end of dictation
presses Return; earlier occurrences remain text. **Restore Default** changes the trigger back to
“enter”. Settings are saved automatically and take effect immediately for both speech engines
and retries. Turning the command off or leaving the trigger blank keeps all dictated words in
the transcript without pressing Return.

## Shortcuts and modes

| Action | Default | Behavior |
|---|---|---|
| Record | `Control + Option + Command` | Two capture modes (below). |
| Retry | `Fn + R` | Re-transcribes the most recent recording and inserts it again. |

Both shortcuts are configurable on the **Audio** page. The record shortcut supports two modes,
toggled by the hands-free setting:

- **Hands-free** — a clean double-tap of the modifiers starts capture; a second double-tap stops
  it. Held modifier combinations and unrelated key presses do not trigger it.
- **Push-to-talk** — capture runs while the modifiers are held and ends on release.

Modifier-only detection is handled by
[`FnControlShortcutMonitor`](../../Sources/Nativ/Features/VoiceCapture/FnControlShortcutMonitor.swift);
shortcut preferences persist in
[`VoiceShortcut`](../../Sources/Nativ/Features/VoiceCapture/VoiceShortcut.swift).

## Recordings and retention

- Recordings are written as temporary `.wav` files with matching `.txt` transcripts.
- Raw audio is deleted automatically after five minutes, or immediately when the app quits; the
  five-minute window is what makes retry possible. Transcript files remain.
- **Show Voice Recordings** in the menu-bar menu opens the recordings folder.

## Audio page

The **Audio** page inspects dictation history and analytics (words per minute, total words, time
saved, streaks), selects the installed speech-to-text model, chooses the capture animation (a
pointer-following waveform or a camera-cutout pill with a reactive orb and timer), and edits both
shortcuts. When no speech-to-text model is installed, it links directly to filtered speech-model
discovery in [Models](models.md).

## Meeting summaries

Recordings use the selected speech-to-text model for transcription and a separate installed
language model for summaries. Summary prompts ask the language model to keep the transcript's
predominant language, including headings and action items, rather than translate it into English.
Long recordings use the summary prompt for each section and a separate merge prompt for the
final combined notes. Both stages use the selected output language.

Open **Audio → Record → Summary settings** to choose a **Language**. Expand **LLM prompts**
(collapsed by default) to edit the **Summary prompt** and **Merge prompt** independently.
The language dropdown defaults to **Auto**, which asks the model to infer the language from the
transcript. Choose **Spanish**, for example, to always produce Spanish summaries instead. An
explicit language selection overrides detection. The language dropdown takes precedence over
language requests in the prompt.

The summary prompt controls notes generated from the transcript; the merge prompt controls how
section summaries are combined for long recordings. Each editor shows the actual instructions
and has its own **Reset prompt** button. Reset a prompt, or leave its editor empty, to use that
stage's default instructions. The transcript or section summaries are appended automatically,
so no placeholders are needed. Language and both prompt preferences save automatically and apply
to automatic summaries and to **Generate summary** or **Regenerate summary** in the Audio library.
Existing summaries change only when regenerated. Chat system instructions are separate from these
summary settings.

## Permissions

- **Microphone** — requested on first capture; required to record.
- **Accessibility** — required so the global shortcut is detected outside the app and so the
  transcript can be inserted at the cursor.

Signed local builds keep Accessibility and microphone authorization across rebuilds because the
signer-bound identity stays stable; unsigned/ad-hoc builds may lose authorization between builds.
