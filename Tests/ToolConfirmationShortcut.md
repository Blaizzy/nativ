# Tool confirmation shortcut

Use a harmless command such as `pwd` that requires approval. Do not test keyboard shortcuts with a destructive command.

1. With an unused shortcut preference, check that a small gray return symbol appears beside Confirm.
2. Click Confirm. On the next approval, the hint should still be visible.
3. With the composer empty, press Return. Only the pending tool should be approved, and the hint should disappear.
4. Restart Nativ and request another approval. Return should still work, but the hint should remain hidden. Hovering Confirm should still explain the shortcut.
5. While approval is pending, type a draft and press Return. It should submit the draft, not approve the tool. An attachment-only draft and prompt editing must also keep their composer behavior.
6. Verify Command-Return still inserts a newline and Return still accepts input-method composition rather than approving a tool.
7. Hold Return across consecutive approvals. Key-repeat events must not approve the next tool.
8. Deny or cancel an approval, switch chats, and check that Return never activates an approval from an inactive chat.

The hint is stored in the app's `chat.hasUsedToolConfirmationReturn` UserDefaults preference. Test resets should use an isolated preferences domain, not the user's running app.

## Image model picker

Ask for an image while more than one compatible model is downloaded, so the picker lists several options.

1. The first downloaded model should be outlined in the accent colour with a filled Use button. Models that still need downloading must never be outlined.
2. With the composer empty, press Down and Up. The outline and the filled Use button should move together through the downloaded models only.
3. Up on the first model and Down on the last should stay put rather than wrapping.
4. Press Return. The outlined model should be the one that runs.
5. Type a draft, then press Up. The draft must be recalled/edited as before, and the outline must not move.
6. With only one model downloaded, Up in an empty composer must still recall the last prompt, since there is nothing to navigate.
7. Press Escape while the picker is open. The selection should cancel.
8. Arrow to the second model, switch to another app and back so the model list rescans, then check the outline is still on the second model rather than snapping to the first.

## Escape on approvals

1. Request an approval for a harmless command such as `pwd`. Press Escape. The tool should be denied, matching the Deny button.
2. While editing a prompt, Escape must still cancel the edit rather than deny.
3. With a draft typed, Escape should still deny, and the draft must survive untouched.

## Decisions belong to the chat on screen

Both keyboard paths act only on the chat you are looking at. Leave a decision pending in one chat and switch to another before testing each case.

1. With an approval pending in chat A, press Escape in chat B. Nothing should be denied, in either chat.
2. With a picker open in chat A, press Up in chat B. Prompt recall must work normally, and chat A's highlight must not move.
3. Return to chat A. Its decision should still be pending and still respond to Escape and the arrows.
4. With approvals pending in two different chats, Escape in a third chat must do nothing.
