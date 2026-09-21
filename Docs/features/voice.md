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

Enable **Audio → Shortcuts → Hey Nativ (Preview)** to start dictation by saying
**“hey nativ”** and continuing directly into your sentence. Two seconds of silence finishes
and inserts the transcript through the normal dictation flow. The record shortcut finishes
early; the overlay's cancel button discards the capture. The wake phrase and preceding audio
are removed from the transcript before spoken commands such as “enter” are processed.
Wake-started captures finish after at most two minutes. Steady background noise can delay
automatic silence detection; use the record shortcut to finish in that case.

The setting is off by default and independent of the keyboard's hands-free mode. While enabled,
it keeps the selected microphone active and five seconds of history in memory. A bundled
[HN-2 Core ML model](https://huggingface.co/nativ-community/HN-2) proposes wake candidates. Each
candidate includes approximately 2.25 seconds before detection plus a 600 ms tail and is sent
to the normal local speech-to-text pipeline for confirmation. A running Nativ server and an
installed speech-to-text model are required; the selected dictation model is used. The Apple
speech recognizer is not used for background listening or confirmation.

Audio continues on the same microphone session while confirmation runs. A rejected candidate
is discarded in memory, and listening resumes after a two-second cooldown. A confirmed
candidate becomes dictation; if speech continued after the confirmation snapshot, the complete
capture is transcribed once more at its endpoint. Otherwise the confirmation result is reused.
Confirmed recordings follow normal five-minute retention, including the pre-roll audio; rejected
candidates are not saved. Retrying a wake recording also removes the wake phrase from its text.

The FP16 model is pinned to revision `db95546d86d2fb8463b421d2319a9e744b226988` (1.36 MB).
This prototype scores two-second, 16 kHz mono windows every **20 ms at threshold 0.3**, with
an adaptive energy gate, 40 ms attack, and 500 ms hangover. The gate uses the quietest fifth of
the last five seconds of 20 ms energy frames to estimate background noise. Its threshold is
6 dB above that estimate, with the existing −50 dBFS minimum. It starts listening immediately,
begins adapting after two seconds, and relearns when the background becomes much quieter.
Core ML permits CPU and Neural Engine execution only. Classifier scoring pauses during
confirmation and accepted capture. GPU ASR is requested only for candidates and final dictation.
Battery impact depends on the microphone, background noise, and candidate frequency.
Inference and confirmation encoding run off the audio callback and main thread.

Dropped audio aborts the candidate instead of joining noncontiguous speech. Confirmation HTTP
requests time out after 15 seconds; the capture also bounds a pending confirmation to 30 seconds
of audio. Disabling the setting, changing microphone, starting keyboard dictation or other audio,
and system sleep/inactive login sessions cancel pending confirmation and clear buffered audio.
Listening resumes after transcription and other audio activity. The settings panel shows
preparation, listening, confirmation, capture, and error status with **Try Again** for recovery.

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
