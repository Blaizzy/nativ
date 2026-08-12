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

## Permissions

- **Microphone** — requested on first capture; required to record.
- **Accessibility** — required so the global shortcut is detected outside the app and so the
  transcript can be inserted at the cursor.

Signed local builds keep Accessibility and microphone authorization across rebuilds because the
signer-bound identity stays stable; unsigned/ad-hoc builds may lose authorization between builds.
