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
