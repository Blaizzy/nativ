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

### “Hey Nativ” wake word

Enable **Audio → Shortcuts → Hey Nativ** to start dictation by saying
**“hey nativ”** and continuing directly into your sentence. Two seconds of silence finishes
and inserts the transcript through the normal dictation flow. The record shortcut finishes
early; the overlay's cancel button discards the capture. The transcript omits the wake phrase
and anything said before it. Spoken commands such as “enter” work as usual.
Wake-started captures finish after at most two minutes. Steady background noise can delay
automatic silence detection; use the record shortcut to finish in that case.

The setting is off by default and independent of the keyboard's hands-free mode. While listening,
it keeps the selected microphone active. A running Nativ server and an installed speech-to-text
model are required; your selected dictation model is used. Speech is processed locally.

**Listening mode** defaults to **Automatic power saving**. On battery, listening pauses after
five minutes without keyboard, mouse, or dictation activity, or one minute in Low Power Mode.
A successful dictation keeps listening available for at least ten more minutes, including in
Low Power Mode. While plugged in, listening stays available without an inactivity timeout.

Move the mouse, press a key, wake the display, or use the dictation shortcut to resume.
Saying “hey nativ” cannot resume a paused microphone. The settings panel shows when listening
is paused to save power. Choose **Always listening** to turn off inactivity pauses. Automatic
pausing lets an ongoing wake-word confirmation or dictation finish first.

Wake-started recordings follow the normal five-minute retention policy. Retrying a recording
also omits the wake phrase from its transcript.

Both modes pause listening during transcription and other audio activity, and while your Mac
or display is asleep or your login session is inactive. It resumes when available. The settings panel shows the
current status and offers **Try Again** if listening encounters an error.

### Keyboard shortcuts

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

## Permissions

- **Microphone** — requested on first capture; required to record.
- **Accessibility** — required so the global shortcut is detected outside the app and so the
  transcript can be inserted at the cursor.

Signed local builds keep Accessibility and microphone authorization across rebuilds because the
signer-bound identity stays stable; unsigned/ad-hoc builds may lose authorization between builds.
