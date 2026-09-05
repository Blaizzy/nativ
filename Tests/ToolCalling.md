# Tool calling verification

`NativModel.tools` owns live availability, request preparation, approval, routing, and cancellation. Chat and routines execute through this runtime. A prepared model request records the schemas the model actually received; discovery cannot authorize another call in that same request.

## Automated checks

```sh
xcodegen generate
xcodebuild test -project Nativ.xcodeproj -scheme Nativ \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/ToolCalling \
  -only-testing:NativTests/ChatToolRuntimeTests \
  -only-testing:NativTests/ChatToolRegistryTests \
  -only-testing:NativTests/CustomToolTests \
  -only-testing:NativTests/NativKitTests \
  -only-testing:NativTests/NativSettingsTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The runtime tests exercise stale requests after Off, server-level overrides, revocation during execution and approval, late approval, caller cancellation, changed schemas and custom definitions, duplicate names, routine restrictions, discovery across model requests, follow-up reuse, and bounded schema exposure. The custom-tool suite runs a real shell process and verifies cancellation.

Auto exposure includes at most three selected tools. A successful search replaces that selection. A follow-up can reuse successful tools from the immediately preceding user turn, subject to current availability and the same limit. Failed calls and earlier unrelated turns do not grant access. The limit bounds tool count, not the size of an individual provider schema.

## App checks

1. Set System Stats to Auto and Tool Search to On. In a fresh chat, ask the model to check CPU and memory usage. Expect discovery, then a separate model request containing and calling the matching tool.
2. Ask it to check again. The recently used Auto tool should be directly available. Set it Off, then repeat: its executor must not run. Other enabled tools retain their own availability and approval rules.
3. Ask for a harmless Terminal command. While approval is pending, turn Terminal Off. The pending operation should fail promptly; a late approval cannot execute it. Turn it On and submit a fresh request to verify normal approval still works.
4. Repeat with an Auto MCP tool. Turn the whole server Off while a call is pending. Verify no further call executes, including an individually On tool on that server.
5. Enable a Kit with one missing component and existing On choices. Only missing components should change. Restart and verify the modes persist.

Run tool-selection checks with both a primary model and a smaller tool-capable model. Include natural paraphrases, parameter-based queries, ambiguous capabilities, no matches, and multi-tool tasks. Search uses the existing tool metadata and parameter schemas; it is lexical retrieval, so semantic synonym recall still needs model-level evaluation.

For performance comparisons, fix the model, sampling settings, task, tools, and cache conditions. Measure task success, all inference requests, total input/output tokens, and elapsed time to the final answer. Report decode tok/s separately. The deterministic runtime tests do not establish model accuracy or an end-to-end speedup.
