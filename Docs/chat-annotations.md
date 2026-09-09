# Chat passage replies

Select text directly in a completed user or assistant message. A **Quote reply** badge appears above the selection; clicking it attaches the passage to the composer. Add a question and send normally. Clicking elsewhere, scrolling, or pressing Escape dismisses the badge.

Selection follows the existing Markdown renderer and is limited to a single rendered block. A selection cannot span separate paragraphs or headings.

Up to five quotes can be staged. Each card can be removed or used to navigate to its source. A selection is limited to 8,000 characters, without silent truncation. Sent quotes remain separate from the user's editable question and survive session persistence, editing, branching, and archive import/export.

## Sending quotes

The selected passages are included with the user's request, each labeled with its source role. Quote replies capture and send only the selected text, without surrounding excerpts, token-distance calculations, or model-window thresholds. The existing conversation history is sent as usual.

Quotes are snapshots that retain the text selected when they were added. Historical quotes are sent again with their containing message. Existing chats without quotes load normally. Previously saved surrounding excerpts are ignored and omitted when the chat is saved again.

## Verification

Quote actions use one identity-comparable handler per chat, passed through the environment above the transcript and composer. The handler holds the chat weakly and does not subscribe message views to chat-wide updates. `ChatAnnotationActionsTests` checks ownership and renders an environment consumer to verify that unrelated chat updates leave it unchanged while capacity and owner changes reach it.

`ChatAnnotationTests` covers native range disambiguation, rendered selections across bold text and links, repeated formatted passages, Unicode, quote-only prompt serialization, immutable snapshots, legacy decoding, discarding previously saved surrounding excerpts, archive ID remapping, and rejection of duplicate message IDs. Run with the existing archive, conversation-branch, and view-model test suites.

`ChatTextSelectionReaderTests` exercises native text selection and guarded instance-level accessibility lookups, including unsupported objects, proxies without formal protocol conformance, empty windows, selection bounds, and message selection while an empty composer retains keyboard focus. It also verifies Services selection export without modifying the general clipboard. The selection bridge never calls accessibility selectors on the `NSApplication` class.

The message observer detects the end of a drag in common run-loop modes because native text tracking can consume mouse-up. Selection is read through instance accessibility methods or, when unavailable, the responder chain's Services interface using a private pasteboard. Services negotiates both modern plain-text and legacy `NSStringPboardType` identifiers. Debug builds log selection lifecycle events under `dev.nativ.chat-selection`, without logging message text.
