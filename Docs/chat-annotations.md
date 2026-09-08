# Chat passage replies

Select text directly in a completed user or assistant message. A **Quote reply** badge appears above the selection; clicking it attaches the passage to the composer. Add a question and send normally. Clicking elsewhere, scrolling, or pressing Escape dismisses the badge. No passage-picker sheet is used.

Up to five quotes can be staged. Each card can be removed or used to navigate to its source. A selection is limited to 8,000 characters, without silent truncation. Sent quotes remain separate from the user's editable question and survive session persistence, editing, branching, and archive import/export.

## Context policy

- The selected text is always included in the user turn supplied to the model.
- At inference time, compare the tokenizer's count for the conversation with its count for the prefix before the selected passage. The difference measures the passage's distance from the current request. The new quote attachments themselves are excluded from this calculation.
- Include surrounding context when distance is **greater than 20%** of the server's effective context limit for the selected model. The same rule applies to all models.
- Keep up to 600 characters on each side. At a message boundary, a neighboring user/assistant message can supply context, labeled with its role. The quote and context are immutable snapshots; a digest detects source edits without duplicating entire source messages in storage.
- If token counting or matching model metadata is unavailable, or the source has changed, include surrounding context conservatively.
- Preserve the existing full-history request construction. This feature does not introduce history truncation or a separate recent-message window. Token-count differences include chat-template framing and are a practical distance measure rather than exact offsets in a single tokenized sequence.

The context decision is saved on the sent quote. Historical quote attachments are serialized again whenever their containing message is included in inference. Existing chats without annotations decode unchanged.

## Verification

`ChatAnnotationTests` covers the 20% boundary, native range disambiguation, rendered selections across bold text and links, repeated formatted passages, Unicode, bounded excerpts, adjacent-message context, prompt serialization, immutable snapshots, legacy decoding, and archive ID remapping. Run with the existing archive, conversation-branch, and view-model test suites.

`ChatTextSelectionReaderTests` exercises native text selection and guarded instance-level accessibility lookups, including unsupported objects, proxies without formal protocol conformance, empty windows, selection bounds, and message selection while an empty composer retains keyboard focus. It also verifies Services selection export without modifying the general clipboard. The selection bridge never calls accessibility selectors on the `NSApplication` class.

The message observer detects the end of a drag in common run-loop modes because native text tracking can consume mouse-up. Selection is read through instance accessibility methods or, when unavailable, the responder chain's Services interface using a private pasteboard. Services negotiates both modern plain-text and legacy `NSStringPboardType` identifiers. Debug builds log selection lifecycle events under `dev.nativ.chat-selection`, without logging message text.
