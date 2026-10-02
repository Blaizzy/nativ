import XCTest
import SwiftTerm
import NativServerKit

final class ChatWorkTests: XCTestCase {
    func testBrowserRequestsResolveURLsAndSelectedTabsWithoutGuessing() throws {
        var state = ChatWorkState()
        let url = "https://example.com/"
        let first = try state.browserItem(for: ChatWorkRequest(action: .open, url: url))
        XCTAssertEqual(first.url, url)
        XCTAssertEqual(state.selectedID, first.id)
        state.close(first.id)
        XCTAssertEqual(try state.browserItem(for: ChatWorkRequest(action: .open, url: url)).id, first.id)
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(try state.browserItem(for: ChatWorkRequest(action: .navigate, url: "https://example.org/")).id, first.id)
        _ = try state.create(title: "Keep this document", kind: .document, content: "Original")
        let second = try state.browserItem(for: ChatWorkRequest(action: .navigate, url: "https://example.org/"))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(try state.browserItem(for: ChatWorkRequest(action: .inspect)).id, second.id)
        let before = state
        XCTAssertThrowsError(try state.browserItem(for: ChatWorkRequest(action: .open, id: UUID(), url: url)))
        XCTAssertThrowsError(try state.browserItem(for: ChatWorkRequest(action: .navigate)))
        XCTAssertThrowsError(try state.browserItem(for: ChatWorkRequest(action: .open, url: "file:///etc/passwd")))
        XCTAssertEqual(before, state)
        state.openNewTab()
        XCTAssertThrowsError(try state.browserItem(for: ChatWorkRequest(action: .inspect)))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(state.itemListJSON().utf8)) as? [[String: Any]])
        XCTAssertEqual(list.first?["url"] as? String, url)
    }

    func testDocumentPreviewRendersMathWithoutRewritingSourceOrCode() throws {
        let source = "# Notes\n\nInline $x^2$ and display:\n\n$$\\frac{1}{2}$$\n\n```swift\nlet price = \"$5\"\n```"
        let rendered = ChatWorkDocument.renderedMarkdown(source)
        XCTAssertTrue(rendered.contains("swiftmath://"))
        XCTAssertTrue(rendered.contains("let price = \"$5\""))
        var state = ChatWorkState()
        let item = try state.create(title: "Notes.md", kind: .document, content: source,
                                    sourceURL: "file:///tmp/notes/Notes.md")
        let restored = try JSONDecoder().decode(ChatWorkState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.selectedItem?.content, source)
        let request = MarkdownImageRequest(markdown: "![Chart](images/chart.png)", baseURL: item.sourceURL.flatMap(URL.init(string:)))
        XCTAssertEqual(request.urls.first?.path, "/tmp/notes/images/chart.png")
    }

    func testDocumentTranslationExtractsProseAndPreservesParagraphs() {
        let source = "# Hello\n\nA **formatted** [sentence](https://example.com).\n\n```swift\nprint(\"Leave code alone\")\n```\n\nSecond paragraph."
        let text = ChatWorkDocument.translationText(source)
        XCTAssertEqual(text, "Hello\n\nA formatted sentence.\n\nSecond paragraph.")
    }

    func testPlainTextCopyPreservesCodeTableColumnsAndChecklistStates() {
        let source = """
            # Notes

            A **formatted** [sentence](https://example.com).

            | Site | Status |
            | --- | --- |
            | Swift | Ready |
            | | Pending |

            - [x] Visited
            - [ ] Review

            ```swift
            if ready {
                print("Copy this too")
            }
            ```
            """
        let text = ChatWorkDocument.plainText(source)
        XCTAssertTrue(text.hasPrefix("Notes\n\nA formatted sentence."))
        XCTAssertTrue(text.contains("Site\tStatus\nSwift\tReady\n\tPending"), text)
        XCTAssertTrue(text.contains("☑ Visited\n☐ Review"), text)
        XCTAssertTrue(text.contains("if ready {\n    print(\"Copy this too\")\n}"), text)
        XCTAssertFalse(text.contains("```"))
    }

    func testNewTabKeepsOpenWorkAndRestoresAcrossLaunches() throws {
        var state = ChatWorkState()
        let document = try state.create(title: "Notes.md", kind: .document, content: "Keep my edits")
        let code = try state.create(title: "main.swift", kind: .code, content: "print(1)")
        state.openNewTab()
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.openIDs, [document.id, code.id])
        let decoded = try JSONDecoder().decode(ChatWorkState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        state.close(code.id)
        XCTAssertNil(state.selectedItem)
        state.open(document.id)
        XCTAssertEqual(state.selectedItem?.content, "Keep my edits")
    }

    func testAddressEntryAcceptsHostsLocalServersAndEncodedSearches() throws {
        for (input, expected) in [
            (" example.com/path ", "https://example.com/path"),
            ("example.com:8080/page", "https://example.com:8080/page"),
            ("localhost:3000/preview", "http://localhost:3000/preview"),
            ("127.0.0.1:8080", "http://127.0.0.1:8080"),
            ("[::1]:3000", "http://[::1]:3000"),
            ("https://example.com/?q=hello", "https://example.com/?q=hello")
        ] {
            XCTAssertEqual(try ChatWorkState.addressURL(input).absoluteString, expected)
        }
        let search = try ChatWorkState.addressURL("Swift & WebKit")
        XCTAssertEqual(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Swift & WebKit")
        for input in ["", " ", "javascript:alert(1)", "file:///tmp/page.html", "ftp://example.com", "https://user:secret@example.com"] {
            XCTAssertThrowsError(try ChatWorkState.addressURL(input), input)
        }
    }

    func testClosingAndReopeningPreservesWorkAndSelectsNeighbor() throws {
        var state = ChatWorkState()
        let document = try state.create(title: "Notes.md", kind: .document, content: "Notes")
        let code = try state.create(title: "main.swift", kind: .code, content: "print(1)")
        state.close(code.id)
        XCTAssertEqual(state.selectedID, document.id)
        state.close(document.id)
        XCTAssertNil(state.selectedID)
        XCTAssertEqual(state.items.count, 2)
        state.open(code.id)
        state.open(code.id)
        XCTAssertEqual(state.openIDs, [code.id])
        XCTAssertEqual(state.selectedItem?.content, "print(1)")
    }

    func testAgentCannotOverwriteAnInterveningUserEdit() throws {
        var state = ChatWorkState()
        let item = try state.create(title: "Notes", kind: .document, content: "Original")
        try state.update(id: item.id, content: "User edit", expectedRevision: 1, author: "You")
        XCTAssertThrowsError(try state.execute(ChatWorkRequest(
            action: .update, id: item.id, content: "Stale agent edit", expectedRevision: 1
        ))) { XCTAssertTrue($0 is ChatWorkError) }
        XCTAssertEqual(state.selectedItem?.content, "User edit")
        XCTAssertEqual(state.selectedItem?.revision, 2)
        let read = try json(state.execute(ChatWorkRequest(action: .read, id: item.id)))
        XCTAssertEqual(read["revision"] as? Int, 2)
        try state.execute(ChatWorkRequest(action: .update, id: item.id, content: "Merged edit", expectedRevision: 2))
        XCTAssertEqual(state.selectedItem?.revision, 3)
        XCTAssertEqual(state.selectedItem?.updatedBy, "Agent")
    }

    func testFailedUpdatesAreAtomic() throws {
        var state = ChatWorkState()
        let item = try state.create(title: "Notes", kind: .document, content: "Keep me")
        let before = state
        XCTAssertThrowsError(try state.update(id: item.id, content: "Changed", expectedRevision: 1, title: " ", author: "Agent"))
        XCTAssertEqual(state, before)
        XCTAssertThrowsError(try state.update(id: item.id, content: String(repeating: "a", count: 256_001), expectedRevision: 1, author: "Agent"))
        XCTAssertEqual(state, before)
    }

    func testOnlyWebURLsCanOpenAndRemoteSourceIsNotEditable() throws {
        for url in ["https://example.com", "http://localhost:3000/preview", "http://127.0.0.1:8080"] {
            XCTAssertNoThrow(try ChatWorkState.webURL(url))
        }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "ftp://example.com", "https://", "https://user:password@example.com"] {
            XCTAssertThrowsError(try ChatWorkState.webURL(url), url)
        }
        var state = ChatWorkState()
        let item = try state.create(title: "Example", kind: .website, url: "https://example.com")
        XCTAssertFalse(item.canEdit)
        XCTAssertThrowsError(try state.update(id: item.id, content: "Changed", expectedRevision: 1, author: "Agent"))
        XCTAssertThrowsError(try state.create(title: "Bad", kind: .code, url: "https://example.com"))
        XCTAssertThrowsError(try state.create(title: "Bad", kind: .website, content: "<h1>Hi</h1>", url: "https://example.com"))
    }

    func testWorkIsPersistedWithItsSessionAndOlderSessionsDecode() throws {
        var state = ChatWorkState()
        let item = try state.create(title: "Page", kind: .website, content: "<h1>Hi</h1>")
        state.isExpanded = true
        state.isWorkOnLeft = true
        let session = ChatSession(id: UUID(), title: "Work", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
        XCTAssertEqual(decoded.workState, state)
        XCTAssertEqual(decoded.workState?.selectedID, item.id)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacyWork = try XCTUnwrap(legacy["workState"] as? [String: Any])
        legacyWork.removeValue(forKey: "isWorkOnLeft")
        legacy["workState"] = legacyWork
        let olderWork = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(olderWork.workState?.isWorkOnLeft)
        XCTAssertEqual(olderWork.workState?.selectedID, item.id)
        legacy.removeValue(forKey: "workState")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(ChatSession.self, from: legacyData).workState)
    }

    func testToolValidationAndResults() throws {
        var state = ChatWorkState()
        XCTAssertThrowsError(try state.execute(ChatWorkRequest(action: .create, title: "Missing kind")))
        XCTAssertThrowsError(try state.execute(ChatWorkRequest(action: .read, id: UUID())))
        let result = try json(state.execute(ChatWorkRequest(action: .create, title: "App", kind: .website, content: "<h1>App</h1>")))
        let id = try XCTUnwrap((result["id"] as? String).flatMap(UUID.init(uuidString:)))
        XCTAssertNil(result["content"])
        XCTAssertEqual(try json(state.execute(ChatWorkRequest(action: .read, id: id)))["content"] as? String, "<h1>App</h1>")
        XCTAssertThrowsError(try state.execute(ChatWorkRequest(action: .update, id: id, content: "No revision")))
        XCTAssertThrowsError(try ChatWorkRequest.decode(MLXChatToolCall(id: "1", function: MLXChatFunctionCall(name: "chat_work", arguments: "invalid"))))
        XCTAssertTrue(ChatToolRegistry.definitions(canEditImage: false).contains { $0.function.name == "chat_work" })
    }

    @MainActor
    func testDispatcherUsesSessionBoundHandlerAndFailsWithoutIt() async throws {
        let call = MLXChatToolCall(id: "1", function: MLXChatFunctionCall(name: "chat_work", arguments: "{\"action\":\"list\"}"))
        var context = ChatToolExecutionContext(imageGenerationModelID: nil, baseURL: URL(string: "http://localhost")!, apiKey: nil, imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: [])
        do {
            _ = try await ChatToolDispatcher.execute(call: call, context: context)
            XCTFail("A background context must not access another chat's work")
        } catch { XCTAssertTrue(error is ChatWorkError) }
        context.workAction = { request in
            XCTAssertEqual(request.action, .list)
            return "[]"
        }
        let result = try await ChatToolDispatcher.execute(call: call, context: context)
        XCTAssertEqual(result.content, "[]")
    }

    func testHTMLDetectionPreservesExistingItemsAndUsesHTMLExportNames() throws {
        let page = "<!DOCTYPE html>\n<html lang='en'><head><title>Game</title></head><body><canvas></canvas></body></html>"
        let examples: [(String, ChatWorkItem.Kind, String, String?)] = [
            ("Snake Game", .document, page, nil),
            ("Snake Game", .code, page, nil),
            ("Untitled", .document, "\u{feff} \n<!-- generated -->\n" + page + "\n<!-- end -->", nil),
            ("Game", .document, "<HTML><BODY>Game</BODY></HTML>", nil),
            ("Game.HTML", .document, "<button>Play</button>", nil),
            ("Game", .code, "<button>Play</button>", " HTML ")
        ]
        for (title, kind, content, language) in examples {
            let item = ChatWorkItem(title: title, kind: kind, content: content, language: language)
            let restored = try JSONDecoder().decode(ChatWorkItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(restored, item)
            XCTAssertEqual(restored.resolvedKind, .website, title)
            XCTAssertEqual(restored.kind, kind, "Detection must not migrate saved source metadata")
            XCTAssertEqual(restored.content, content)
            XCTAssertTrue(restored.canEdit)
            XCTAssertTrue(restored.exportFilename.lowercased().hasSuffix(".html"))
            var state = ChatWorkState(items: [restored], openIDs: [restored.id], selectedID: restored.id)
            XCTAssertEqual(try state.browserItem(for: ChatWorkRequest(action: .inspect)).id, restored.id)
            let result = try state.execute(ChatWorkRequest(action: .read, id: restored.id))
            let read = try json(result)
            XCTAssertEqual(read["kind"] as? String, "website")
            struct ReadContent: Decodable { var content: String }
            XCTAssertEqual(try JSONDecoder().decode(ReadContent.self, from: Data(result.utf8)).content, content)
            XCTAssertEqual(read["revision"] as? Int, 1)
        }
    }

    func testMarkdownAndCodeExamplesDoNotBecomeExecutableWebpages() {
        let page = "<!doctype html><html><body>Example</body></html>"
        for content in ["# HTML notes\n\n" + page, "```html\n" + page + "\n```",
                        "<details><summary>Notes</summary>Text</details>",
                        "An example: <html><body>Hi</body></html>", "<html>Example snippet",
                        "const template = `" + page + "`;", "&lt;html&gt;Example&lt;/html&gt;"] {
            for kind in [ChatWorkItem.Kind.document, .code] {
                let item = ChatWorkItem(title: "Notes", kind: kind, content: content)
                XCTAssertEqual(item.resolvedKind, kind, content)
                XCTAssertEqual(item.exportFilename, "Notes")
            }
        }
    }

    private func json(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
}

@MainActor
final class ChatWorkSessionTests: XCTestCase {
    func testSharedTerminalRunsInTheExistingShellAndKeepsConsentBoundToItsTarget() async throws {
        let (root, _, original) = try fixture()
        let folder = root.appendingPathComponent("with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "visible".write(to: folder.appendingPathComponent("file-from-shared-shell.txt"), atomically: true, encoding: .utf8)
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Existing terminal", kind: .terminal)
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let terminal = chat.workTerminal(for: item, sessionID: original.id)
        defer { terminal.stop() }
        terminal.startIfNeeded(environment: ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        try await terminalReady(terminal)
        let request = try chat.resolvedWorkRequest(ChatWorkRequest(action: .run,
            command: "export NATIV_SHELL_TEST=42\ncd '\(folder.path)'\nprintf '\\nSHARED_%s:%s\\n' \"$NATIV_SHELL_TEST\" \"$PWD\""), in: original.id)
        do {
            _ = try await chat.executeWorkAction(request, in: original.id)
            XCTFail("A shell command must require consent")
        } catch { XCTAssertEqual(error as? ChatTerminalToolError, .approvalRequired) }
        // Changing the selected tab while approval is pending must not retarget the command.
        try chat.createWorkItem(title: "Another terminal", kind: .terminal)
        let result = try await chat.executeWorkAction(request, in: original.id, terminalApprovalGranted: true)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, item.id.uuidString)
        XCTAssertEqual((payload["cwd"] as? String)?.replacingOccurrences(of: "/private/var/", with: "/var/"), folder.path)
        XCTAssertEqual(payload["exit_code"] as? Int, 0)
        XCTAssertEqual(payload["running"] as? Bool, false)
        XCTAssertEqual(chat.workState.selectedItem?.terminalWorkingDirectory, payload["cwd"] as? String)
        XCTAssertTrue((payload["content"] as? String)?.contains("SHARED_42:") == true, result)
        let listing = try await chat.executeWorkAction(ChatWorkRequest(action: .run, id: item.id, command: "ls"),
                                                      in: original.id, terminalApprovalGranted: true)
        XCTAssertTrue(listing.contains("file-from-shared-shell.txt"), listing)
        XCTAssertEqual(chat.workState.items.count, 2)

        let stale = try chat.resolvedWorkRequest(ChatWorkRequest(action: .run, id: item.id, command: "printf should-not-run"), in: original.id)
        let native = try XCTUnwrap(terminal.view as? LocalProcessTerminalView)
        native.send(txt: "echo unsent")
        do {
            _ = try await chat.executeWorkAction(stale, in: original.id, terminalApprovalGranted: true)
            XCTFail("User input must invalidate pending approval")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(terminal.text.contains("should-not-run"))
        terminal.interrupt()
        try await terminalReady(terminal)
        let beforeClose = try chat.resolvedWorkRequest(ChatWorkRequest(action: .run, id: item.id, command: "printf should-not-run"), in: original.id)
        chat.closeWorkItem(item.id)
        chat.openWorkItem(item.id)
        do {
            _ = try await chat.executeWorkAction(beforeClose, in: original.id, terminalApprovalGranted: true)
            XCTFail("A restarted shell must invalidate pending approval")
        } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        chat.closeWorkItem(item.id)
    }

    func testSharedTerminalReadInterruptAndSafetyValidation() async throws {
        let (root, _, original) = try fixture()
        try """
        function __test_prompt_hook() { print -r -- $? > "$HOME/hook-status"; }
        precmd_functions=(__test_prompt_hook)
        """.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Terminal", kind: .terminal)
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let terminal = chat.workTerminal(for: item, sessionID: original.id)
        defer { terminal.stop() }
        terminal.startIfNeeded(environment: ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin"])
        try await terminalReady(terminal)
        for command in ["rm -rf /", "echo test\r", "\u{1b}[201~bad", ""] {
            XCTAssertThrowsError(try chat.resolvedWorkRequest(ChatWorkRequest(action: .run, command: command), in: original.id))
        }
        XCTAssertThrowsError(try chat.resolvedWorkRequest(ChatWorkRequest(action: .run, command: "ls", timeout: 31), in: original.id))
        let running = try await chat.executeWorkAction(ChatWorkRequest(action: .run, command: "sleep 10", timeout: 1),
                                                       in: original.id, terminalApprovalGranted: true)
        XCTAssertTrue(running.contains("\"running\":true"), running)
        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .interrupt), in: original.id, terminalApprovalGranted: true)
        try await terminalReady(terminal)
        let read = try await chat.executeWorkAction(ChatWorkRequest(action: .inspect, id: item.id), in: original.id)
        XCTAssertTrue(read.contains("\"running\":false"), read)
        let failed = try await chat.executeWorkAction(ChatWorkRequest(action: .run, command: "false"),
                                                      in: original.id, terminalApprovalGranted: true)
        XCTAssertTrue(failed.contains("\"exit_code\":1"), failed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("hook-status"), encoding: .utf8), "1\n",
                       "A failed command must still run the user's prompt hooks with the original exit status")
    }

    private func terminalReady(_ terminal: ChatWorkTerminalSession) async throws {
        for _ in 0..<500 {
            if terminal.atPrompt && !terminal.commandIsRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Shell did not reach a prompt: \(terminal.text)")
        throw CancellationError()
    }

    func testClosingAgentTerminalCancelsItsCommandWithoutReopeningTheTab() async throws {
        let (root, _, original) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let request = TerminalProcessRequest(command: "printf 'cancel_%s\\n' ready; sleep 5; printf 'finished'",
                                             currentDirectoryURL: root, timeout: 10,
                                             environment: ChatTerminalToolExecutor.scrubbedEnvironment(resolvedPath: "/usr/bin:/bin"))
        let task = Task { try await chat.runWorkTerminalCommand(request, in: original.id) }
        for _ in 0..<100 {
            if let item = chat.workState.selectedItem,
               chat.workTerminals.existing(itemID: item.id, sessionID: original.id)?.text.contains("cancel_ready") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let terminal = try XCTUnwrap(chat.workTerminals.existing(itemID: item.id, sessionID: original.id))
        XCTAssertTrue(terminal.text.contains("cancel_ready"))
        let start = Date()
        chat.closeWorkItem(item.id)
        do {
            _ = try await task.value
            XCTFail("Closing the agent terminal must cancel the command")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(terminal.isRunning)
        XCTAssertFalse(chat.workState.openIDs.contains(item.id))
        XCTAssertNil(chat.workTerminals.existing(itemID: item.id, sessionID: original.id))
    }

    func testAgentTerminalStreamsAndPersistsInItsOriginatingChat() async throws {
        let (root, store, original) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let request = TerminalProcessRequest(command: "printf 'stream_%s\\n' before; sleep 0.5; printf 'after\\n'",
                                             currentDirectoryURL: root, timeout: 10,
                                             environment: ChatTerminalToolExecutor.scrubbedEnvironment(resolvedPath: "/usr/bin:/bin"))
        let task = Task { try await chat.runWorkTerminalCommand(request, in: original.id) }
        var terminal: ChatWorkTerminalSession?
        for _ in 0..<100 {
            if let item = chat.workState.selectedItem {
                terminal = chat.workTerminals.existing(itemID: item.id, sessionID: original.id)
                if terminal?.text.contains("stream_before") == true { break }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let live = try XCTUnwrap(terminal)
        XCTAssertTrue(live.text.contains("stream_before"))
        XCTAssertTrue(live.isRunning)
        // Switching chats cannot move the result to the newly selected chat.
        chat.createSession()
        XCTAssertNotEqual(chat.currentSessionID, original.id)
        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(live.isRunning)
        XCTAssertTrue(chat.workState.items.isEmpty)
        let saved = try XCTUnwrap(store.loadSession(id: original.id)?.workState?.selectedItem)
        XCTAssertEqual(saved.kind, .terminal)
        XCTAssertTrue(saved.content.contains("before\nafter"))
        let read = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: saved.id), in: original.id)
        XCTAssertTrue(read.contains("after"))
        chat.deleteSession(original.id)
        XCTAssertNil(chat.workTerminals.existing(itemID: saved.id, sessionID: original.id))
    }

    func testWorkFeedbackAddsStructuredAnnotationsWhilePreservingTheDraftAndPastedText() async throws {
        let (root, _, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let selection = ChatWorkPageAnnotation(url: "https://example.com/game", selector: "canvas#game",
                                               text: "Board", x: 12, y: 24)
        let cases: [(ChatWorkItem.Kind, String?, ChatWorkPageAnnotation?)] = [
            (.website, nil, selection), (.document, nil, nil), (.website, "https://example.com/page", nil)
        ]
        for (kind, url, annotation) in cases {
            try chat.createWorkItem(title: "Work", kind: kind, content: url == nil ? "Selected text" : "", url: url)
            let item = try XCTUnwrap(chat.workState.selectedItem)
            let target = ChatWorkFeedback(item: item, sessionID: session.id,
                annotation: annotation, selectedText: kind == .document ? "Selected text" : "")
            chat.draft = "Existing request"
            chat.attachPastedText("Pasted context", replacing: NSRange(location: 16, length: 0), undoManager: nil)
            let draft = ChatPastedTextDraft(text: chat.draft, pastedTexts: chat.pendingPastedTexts)
            let focusToken = chat.composerFocusToken
            chat.toggleWorkPaneExpanded()
            try chat.addWorkFeedback(target)
            XCTAssertEqual(ChatPastedTextDraft(text: chat.draft, pastedTexts: chat.pendingPastedTexts), draft)
            XCTAssertTrue(chat.messages.isEmpty)
            XCTAssertGreaterThan(chat.composerFocusToken, focusToken)
            XCTAssertEqual(chat.workState.isExpanded, false)
            let expected = ChatWorkAnnotationReference(itemID: item.id, title: item.title, revision: item.revision,
                selection: annotation, url: url, selectedText: kind == .document ? "Selected text" : nil)
            XCTAssertEqual(chat.pendingAnnotations.map(\.workReference), [expected])
            XCTAssertEqual(chat.pendingAnnotations.first?.quote, annotation?.text ?? target.selectedText)
            chat.removeAnnotation(try XCTUnwrap(chat.pendingAnnotations.first?.id))
            XCTAssertTrue(chat.pendingAnnotations.isEmpty)
            XCTAssertEqual(chat.composerText, draft.editableText)
            chat.draft = ""
            for _ in 0..<ChatAnnotation.maximumCount { try chat.addWorkFeedback(target) }
            XCTAssertThrowsError(try chat.addWorkFeedback(target))
            XCTAssertTrue(chat.draft.isEmpty)
            XCTAssertTrue(chat.composerText.isEmpty)
            chat.removeAnnotation(chat.pendingAnnotations[0].id)
            XCTAssertEqual(chat.pendingAnnotations.count, ChatAnnotation.maximumCount - 1)
            chat.createSession()
            XCTAssertTrue(chat.pendingAnnotations.isEmpty)
            XCTAssertThrowsError(try chat.addWorkFeedback(target))
            chat.selectSession(session.id)
        }
    }

    func testOmittedUpdateIDUsesReadReceiptAndPreservesRevisionAndConsentTargets() async throws {
        let (root, _, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Original")
        let first = try XCTUnwrap(chat.workState.selectedItem)
        let request = ChatWorkRequest(action: .update, title: first.title, kind: .document,
                                      content: "Agent edit", expectedRevision: 1)
        XCTAssertThrowsError(try chat.resolvedWorkRequest(request, in: session.id))
        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: first.id), in: session.id)
        XCTAssertEqual(try chat.resolvedWorkRequest(request, in: session.id).id, first.id)
        XCTAssertThrowsError(try chat.resolvedWorkRequest(request, in: UUID()))
        var wrongTitle = request
        wrongTitle.title = "Other.md"
        XCTAssertThrowsError(try chat.resolvedWorkRequest(wrongTitle, in: session.id))
        var wrongRevision = request
        wrongRevision.expectedRevision = 2
        XCTAssertThrowsError(try chat.resolvedWorkRequest(wrongRevision, in: session.id))

        let approved = try chat.resolvedWorkRequest(request, in: session.id)
        try chat.createWorkItem(title: "Other.md", kind: .document, content: "Keep this")
        let other = try XCTUnwrap(chat.workState.selectedItem)
        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: other.id), in: session.id)
        _ = try await chat.executeWorkAction(approved, in: session.id)
        XCTAssertEqual(chat.workState.items.first { $0.id == first.id }?.content, "Agent edit")
        XCTAssertEqual(chat.workState.items.first { $0.id == other.id }?.content, "Keep this")

        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: first.id), in: session.id)
        try chat.updateWorkItem(first.id, content: "User edit", previousContent: "Agent edit")
        var stale = request
        stale.expectedRevision = 2
        do {
            _ = try await chat.executeWorkAction(stale, in: session.id)
            XCTFail("An omitted ID must not bypass an intervening user edit")
        } catch {
            guard case ChatWorkError.conflict = error else { return XCTFail("Expected a revision conflict: \(error)") }
        }
        XCTAssertEqual(chat.workState.items.first { $0.id == first.id }?.content, "User edit")
        var missingID = ChatWorkState()
        XCTAssertThrowsError(try missingID.execute(ChatWorkRequest(action: .update))) {
            XCTAssertTrue($0.localizedDescription.contains("requires id"))
        }
    }

    func testTwoWebsitesAndMarkdownCoexistInOneChat() async throws {
        let server = try ChatWorkHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        var context = ChatToolExecutionContext(imageGenerationModelID: nil, baseURL: base, apiKey: nil,
            imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: [])
        context.workAction = { request in try await chat.executeWorkAction(request, in: session.id) }
        func run(_ arguments: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let call = MLXChatToolCall(id: UUID().uuidString, function: MLXChatFunctionCall(
                name: "chat_work", arguments: String(decoding: data, as: UTF8.self)))
            let result = try await ChatToolDispatcher.execute(call: call, context: context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        }

        let first = try await run(["action": "open", "url": base.absoluteString])
        let firstID = try XCTUnwrap(first["id"] as? String)
        let controls = try XCTUnwrap(first["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(controls.first { $0["label"] as? String == "Search terms" }?["id"] as? String)
        _ = try await run(["action": "type", "element_id": input, "text": "Keep this tab's input"])
        let secondURL = base.appendingPathComponent("next").absoluteString
        let second = try await run(["action": "open", "url": secondURL])
        let secondID = try XCTUnwrap(second["id"] as? String)
        XCTAssertNotEqual(firstID, secondID)

        let markdown = "# Browsing notes\n\n| Tab | Status |\n| --- | --- |\n| First | Open |\n| Second | Open |\n\n- Two websites in one chat\n- One shared document\n"
        // The live small model omitted both kind on Markdown creation and id on update.
        let document = try await run(["action": "create", "title": "Browsing notes.md", "content": markdown])
        let documentID = try XCTUnwrap(document["id"] as? String)
        let read = try await run(["action": "read", "id": documentID])
        XCTAssertEqual(read["content"] as? String, markdown)
        let revision = try XCTUnwrap(read["revision"] as? Int)
        let updatedMarkdown = markdown + "\n## Result\n\nBoth browser tabs keep their state.\n"
        _ = try await run(["action": "update", "title": "Browsing notes.md", "kind": "document",
                           "content": updatedMarkdown, "expected_revision": revision])

        let firstAgain = try await run(["action": "inspect", "id": firstID])
        XCTAssertEqual(firstAgain["url"] as? String, base.absoluteString)
        let preservedControls = try XCTUnwrap(firstAgain["elements"] as? [[String: Any]])
        XCTAssertEqual(preservedControls.first { $0["label"] as? String == "Search terms" }?["value"] as? String,
                       "Keep this tab's input")
        let secondAgain = try await run(["action": "inspect", "id": secondID])
        XCTAssertEqual(secondAgain["url"] as? String, secondURL)
        // A reference still belongs to its inspected tab after another tab is selected.
        let firstControls = try XCTUnwrap(firstAgain["elements"] as? [[String: Any]])
        let firstInput = try XCTUnwrap(firstControls.first { $0["label"] as? String == "Search terms" }?["id"] as? String)
        let typed = try await run(["action": "type", "element_id": firstInput, "text": "Correct background tab"])
        XCTAssertEqual(typed["id"] as? String, firstID)
        XCTAssertThrowsError(try chat.resolvedWorkRequest(ChatWorkRequest(action: .click, elementID: firstInput), in: session.id))
        XCTAssertThrowsError(try chat.resolvedWorkRequest(ChatWorkRequest(action: .click, elementID: firstInput), in: UUID()))
        let resultURL = base.appendingPathComponent("result").absoluteString
        _ = try await run(["action": "navigate", "id": secondID, "url": resultURL])
        _ = try await run(["action": "open", "id": documentID])

        XCTAssertEqual(chat.currentSessionID, session.id)
        XCTAssertEqual(chat.workState.items.count, 3)
        XCTAssertEqual(Set(chat.workState.openIDs.map(\.uuidString)), Set([firstID, secondID, documentID]))
        let saved = try XCTUnwrap(store.loadSession(id: session.id)?.workState)
        XCTAssertEqual(saved.selectedItem?.content, updatedMarkdown)
        XCTAssertEqual(saved.items.first { $0.id.uuidString == firstID }?.url, base.absoluteString)
        XCTAssertEqual(saved.items.first { $0.id.uuidString == secondID }?.url, resultURL)

        chat.createSession()
        chat.selectSession(session.id)
        XCTAssertEqual(chat.workState, saved)
        let restored = subject(root)
        try await loaded(restored)
        restored.selectSession(session.id)
        XCTAssertEqual(restored.workState, saved)
    }

    func testGeneratedWebsiteCanBeCreatedOperatedUpdatedAndRestored() async throws {
        func json(_ value: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        }
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let created = try json(await chat.executeWorkAction(ChatWorkRequest(action: .create, title: "Game",
            kind: .website, content: "<button onclick=\"this.textContent='Started'\">Start</button>"), in: session.id))
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(created["id"] as? String)))
        XCTAssertEqual(created["editable"] as? Bool, true)
        XCTAssertEqual(created["revision"] as? Int, 1)
        let controls = try XCTUnwrap(created["elements"] as? [[String: Any]])
        let control = try XCTUnwrap(controls.first?["id"] as? String)
        let clicked = try json(await chat.executeWorkAction(ChatWorkRequest(action: .click, elementID: control), in: session.id))
        XCTAssertTrue((clicked["text"] as? String)?.contains("Started") == true)
        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: id), in: session.id)
        let html = "<h1>Updated game</h1><script>document.body.dataset.ready='yes'</script>"
        let updated = try json(await chat.executeWorkAction(ChatWorkRequest(action: .update, content: html,
            expectedRevision: 1), in: session.id))
        XCTAssertEqual(updated["revision"] as? Int, 2)
        XCTAssertEqual(updated["text"] as? String, "Updated game")
        XCTAssertEqual(updated["runtime_errors"] as? [String], [])
        let saved = try XCTUnwrap(store.loadSession(id: session.id)?.workState?.selectedItem)
        XCTAssertNil(saved.url)
        XCTAssertEqual(saved.content, html)
        XCTAssertTrue(saved.canEdit)
        let restored = subject(root)
        try await loaded(restored)
        restored.selectSession(session.id)
        let reopened = try json(await restored.executeWorkAction(ChatWorkRequest(action: .open, id: id), in: session.id))
        XCTAssertEqual(reopened["text"] as? String, "Updated game")
        XCTAssertNotEqual(reopened["url"] as? String, updated["url"] as? String)
        XCTAssertEqual(restored.workState.selectedItem, saved)
    }

    func testExistingHTMLDocumentOpensAsLiveWebsiteAndRemainsEditable() async throws {
        let (root, store, original) = try fixture()
        let html = """
            <!DOCTYPE html><html><head><title>Snake Game</title></head><body>
            <button onclick="this.textContent='Running'">Play</button></body></html>
            """
        let item = ChatWorkItem(title: "Snake Game", kind: .document, content: html, updatedBy: "Agent")
        var session = original
        session.workState = ChatWorkState(items: [item], openIDs: [item.id], selectedID: item.id, isVisible: true)
        XCTAssertTrue(store.saveSession(session))
        let chat = subject(root)
        try await loaded(chat)
        chat.selectSession(session.id)
        func json(_ value: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        }
        let opened = try json(await chat.executeWorkAction(ChatWorkRequest(action: .open, id: item.id), in: session.id))
        XCTAssertEqual(opened["title"] as? String, "Snake Game")
        XCTAssertTrue((opened["url"] as? String)?.hasPrefix("http://127.0.0.1:") == true)
        let controls = try XCTUnwrap(opened["elements"] as? [[String: Any]])
        let button = try XCTUnwrap(controls.first?["id"] as? String)
        let clicked = try json(await chat.executeWorkAction(ChatWorkRequest(action: .click, elementID: button), in: session.id))
        XCTAssertTrue((clicked["text"] as? String)?.contains("Running") == true)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState?.selectedItem, item)
        let read = try json(await chat.executeWorkAction(ChatWorkRequest(action: .read, id: item.id), in: session.id))
        XCTAssertEqual(read["kind"] as? String, "website")
        let updated = try json(await chat.executeWorkAction(ChatWorkRequest(action: .update, kind: .website,
            content: html.replacingOccurrences(of: "Play", with: "Restart"), expectedRevision: 1), in: session.id))
        XCTAssertEqual(updated["kind"] as? String, "website")
        XCTAssertEqual(updated["revision"] as? Int, 2)
        XCTAssertTrue((updated["text"] as? String)?.contains("Restart") == true)
        XCTAssertNil(store.loadSession(id: session.id)?.workState?.selectedItem?.url)
        let created = try json(await chat.executeWorkAction(ChatWorkRequest(action: .create, title: "Another Game",
            kind: .document, content: html), in: session.id))
        XCTAssertEqual(created["kind"] as? String, "website")
        XCTAssertNotNil(created["elements"])
    }

    func testAgentOpensAndOperatesAWebsiteThroughTheSessionDispatcher() async throws {
        let server = try ChatWorkHTTPFixture()
        let base = try await server.start()
        defer { server.stop() }
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        var context = ChatToolExecutionContext(imageGenerationModelID: nil, baseURL: base, apiKey: nil,
            imageReferences: [], modelSearchPath: "", additionalModelSearchPaths: [])
        context.workAction = { request in try await chat.executeWorkAction(request, in: session.id) }
        func run(_ arguments: [String: String]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let call = MLXChatToolCall(id: UUID().uuidString, function: MLXChatFunctionCall(
                name: "chat_work", arguments: String(decoding: data, as: UTF8.self)))
            let result = try await ChatToolDispatcher.execute(call: call, context: context)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
        }
        func element(_ label: String, in page: [String: Any]) throws -> String {
            let elements = try XCTUnwrap(page["elements"] as? [[String: Any]])
            return try XCTUnwrap(elements.first { $0["label"] as? String == label }?["id"] as? String)
        }

        // These are the exact argument shapes that failed in the user's conversation.
        let opened = try await run(["action": "open", "url": base.absoluteString])
        let id = try XCTUnwrap(opened["id"] as? String)
        XCTAssertEqual(opened["title"] as? String, "Browser fixture")
        XCTAssertEqual(opened["url"] as? String, base.absoluteString)
        XCTAssertTrue(chat.workState.isVisible)
        XCTAssertEqual(chat.workState.selectedID?.uuidString, id)
        let typed = try await run(["action": "type", "element_id": element("Search terms", in: opened), "text": "Nativ"])
        let result = try await run(["action": "click", "element_id": element("Search", in: typed)])
        XCTAssertEqual(result["title"] as? String, "Search results")
        XCTAssertTrue((result["url"] as? String)?.contains("q=Nativ") == true)
        XCTAssertEqual(result["id"] as? String, id)

        let nextURL = base.appendingPathComponent("next").absoluteString
        let navigated = try await run(["action": "navigate", "url": nextURL])
        XCTAssertEqual(navigated["title"] as? String, "Next page")
        XCTAssertEqual(navigated["url"] as? String, nextURL)
        XCTAssertEqual(navigated["id"] as? String, id)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState?.selectedItem?.url, nextURL)
        // Access through the pane's pool must not reload the original saved URL.
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let browser = chat.workBrowser(for: item, sessionID: session.id)
        XCTAssertEqual(browser.webView.url?.absoluteString, nextURL)
        let back = try await run(["action": "back"])
        XCTAssertEqual(back["title"] as? String, "Search results")
        let forward = try await run(["action": "forward"])
        XCTAssertEqual(forward["url"] as? String, nextURL)
        let reloaded = try await run(["action": "reload"])
        XCTAssertEqual(reloaded["title"] as? String, "Next page")
        let reopened = try await run(["action": "open", "url": nextURL])
        XCTAssertEqual(reopened["id"] as? String, id)
        XCTAssertEqual(chat.workState.items.count, 1)
    }

    private func fixture() throws -> (URL, ChatSessionStore, ChatSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChatSessionStore(chatDirectory: root.appendingPathComponent("Chat"),
                                     mediaStore: MediaAssetStore(rootDirectory: root.appendingPathComponent("Media")))
        let now = Date()
        let session = ChatSession(id: UUID(), title: "Existing", customTitle: "My existing chat",
                                  createdAt: now, updatedAt: now, messages: [],
                                  importedSystemPrompt: "Keep this prompt", personalizationSnapshot: "Keep this context")
        XCTAssertTrue(store.saveSession(session))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, store, session)
    }

    private func subject(_ root: URL, windowID: UUID = UUID(), hub: PersistedDataChangeHub = .init(),
                         activity: InferenceActivityCoordinator = .init()) -> ChatViewModel {
        ChatViewModel(windowID: windowID, persistedDataChanges: hub, inferenceActivity: activity,
                      projectStore: ChatProjectStore(storageURL: root.appendingPathComponent("Projects.json")),
                      sessionDirectory: root.appendingPathComponent("Chat"))
    }

    private func loaded(_ subjects: ChatViewModel...) async throws {
        for _ in 0..<1_000 {
            if subjects.allSatisfy({ !$0.isLoadingSessions }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Chat loading did not finish")
        throw CancellationError()
    }

    func testAgentAndPaneShareFilesAndImportExternalEditsWithRevisionChecks() async throws {
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        func json(_ value: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        }
        let created = try json(await chat.executeWorkAction(ChatWorkRequest(action: .create, title: "Notes.md",
            kind: .document, content: "# Original"), in: session.id))
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let url = try XCTUnwrap(chat.workFileURL(for: item))
        XCTAssertEqual(created["file_path"] as? String, url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Original")
        try chat.updateWorkItem(item.id, content: "# Pane edit", previousContent: "# Original")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Pane edit")
        _ = try await chat.executeWorkAction(ChatWorkRequest(action: .read, id: item.id), in: session.id)
        try "# Terminal edit".write(to: url, atomically: true, encoding: .utf8)
        chat.closeWorkItem(item.id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Terminal edit")
        do {
            _ = try await chat.executeWorkAction(ChatWorkRequest(action: .update, id: item.id,
                content: "Stale", expectedRevision: 2), in: session.id)
            XCTFail("A stale revision must not overwrite an external edit")
        } catch ChatWorkError.conflict {
            // The disk edit increments the revision before the agent update is applied.
        } catch { XCTFail("Unexpected error: \(error)") }
        let read = try json(await chat.executeWorkAction(ChatWorkRequest(action: .read, id: item.id), in: session.id))
        XCTAssertEqual(read["content"] as? String, "# Terminal edit")
        XCTAssertEqual(read["revision"] as? Int, 3)
        XCTAssertEqual(read["file_path"] as? String, url.path)
        let updated = try json(await chat.executeWorkAction(ChatWorkRequest(action: .update, id: item.id,
            content: "# Agent edit", expectedRevision: 3), in: session.id))
        XCTAssertEqual(updated["file_path"] as? String, url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Agent edit")
        let list = try await chat.executeWorkAction(ChatWorkRequest(action: .list), in: session.id)
        let listed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]])
        XCTAssertEqual(listed.first?["file_path"] as? String, url.path)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState?.selectedItem?.content, "# Agent edit")
        let restored = subject(root)
        try await loaded(restored)
        restored.selectSession(session.id)
        try restored.refreshWorkFiles()
        restored.openWorkItem(item.id)
        XCTAssertEqual(restored.workState.items.count, 1)
        XCTAssertEqual(restored.workState.selectedItem?.id, item.id)
        XCTAssertEqual(restored.workFileURL(for: item), url)
    }

    func testRenamingAFileUpdatesItsTabAndDiskPathWithoutLosingExternalEdits() async throws {
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Untitled.md", kind: .document, content: "# Original")
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let originalURL = try XCTUnwrap(chat.workFileURL(for: item))
        try "# From editor".write(to: originalURL, atomically: true, encoding: .utf8)
        try chat.renameWorkItem(item.id, name: "Project notes", previousTitle: item.title)
        let renamed = try XCTUnwrap(chat.workState.selectedItem)
        XCTAssertEqual(renamed.id, item.id)
        XCTAssertEqual(renamed.title, "Project notes.md")
        XCTAssertEqual(renamed.content, "# From editor")
        XCTAssertEqual(chat.workState.items.count, 1)
        XCTAssertEqual(chat.workState.openIDs, [item.id])
        let url = try XCTUnwrap(chat.workFileURL(for: renamed))
        XCTAssertEqual(url.lastPathComponent, "Project notes.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# From editor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(store.loadSession(id: session.id)?.workState?.selectedItem, renamed)
        for invalidName in ["", "../outside.md", "bad/name.md", "bad:name.md"] {
            XCTAssertThrowsError(try chat.renameWorkItem(item.id, name: invalidName, previousTitle: renamed.title))
        }
        XCTAssertThrowsError(try chat.renameWorkItem(item.id, name: "Stale.md", previousTitle: item.title))
        XCTAssertEqual(chat.workState.selectedItem, renamed)
        let restored = subject(root)
        try await loaded(restored)
        restored.selectSession(session.id)
        XCTAssertEqual(restored.workState.selectedItem, renamed)
    }

    func testDeleteRemovesOnlyItsFileAndTabAndDoesNotRecreateIt() async throws {
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let original = root.appendingPathComponent("Imported.md")
        try "Original import".write(to: original, atomically: true, encoding: .utf8)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Original import",
                                sourceURL: original.absoluteString)
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let url = try XCTUnwrap(chat.workFileURL(for: item))
        try "External edit".write(to: url, atomically: true, encoding: .utf8)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Keep this duplicate name")
        let kept = try XCTUnwrap(chat.workState.selectedItem)
        chat.openWorkItem(item.id)
        let trashURL = root.appendingPathComponent("Trashed.md")
        try chat.deleteWorkItem(item.id) { source in
            XCTAssertEqual(source, url)
            try FileManager.default.moveItem(at: source, to: trashURL)
            return trashURL
        }
        XCTAssertEqual(chat.workState.items, [kept])
        XCTAssertEqual(chat.workState.openIDs, [kept.id])
        XCTAssertEqual(chat.workState.selectedItem, kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: trashURL, encoding: .utf8), "External edit")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "Original import")
        XCTAssertEqual(store.loadSession(id: session.id)?.workState, chat.workState)
        try chat.refreshWorkFiles()
        let restored = subject(root)
        try await loaded(restored)
        restored.selectSession(session.id)
        XCTAssertEqual(restored.workState.items, [kept])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // Deleting from Files also works for an already closed tab.
        restored.closeWorkItem(kept.id)
        try restored.deleteWorkItem(kept.id) { source in
            let destination = root.appendingPathComponent("Trashed second.md")
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }
        XCTAssertTrue(restored.workState.items.isEmpty)
        XCTAssertTrue(restored.workState.openIDs.isEmpty)
        XCTAssertNil(restored.workState.selectedID)
    }

    func testDeleteFailuresKeepFileAndChatReferencesIntact() async throws {
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Notes.md", kind: .document, content: "Keep me")
        let item = try XCTUnwrap(chat.workState.selectedItem)
        let url = try XCTUnwrap(chat.workFileURL(for: item))
        let before = chat.workState
        XCTAssertThrowsError(try chat.deleteWorkItem(item.id) { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(chat.workState, before)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState, before)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Keep me")
        // Force the JSON save to fail after the source has moved to Trash.
        let sessionURL = root.appendingPathComponent("Chat/Sessions/\(session.id.uuidString).json")
        let backupURL = root.appendingPathComponent("Session backup.json")
        try FileManager.default.moveItem(at: sessionURL, to: backupURL)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: false)
        let trashURL = root.appendingPathComponent("Trashed.md")
        XCTAssertThrowsError(try chat.deleteWorkItem(item.id) { source in
            try FileManager.default.moveItem(at: source, to: trashURL)
            return trashURL
        })
        XCTAssertEqual(chat.workState, before)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashURL.path))
        try FileManager.default.removeItem(at: sessionURL)
        try FileManager.default.moveItem(at: backupURL, to: sessionURL)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState, before)
    }

    func testFailedFileSaveDoesNotPublishUnsavedWork() async throws {
        let (root, store, session) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let before = chat.workState
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("Chat/Files"))
        XCTAssertThrowsError(try chat.createWorkItem(title: "Unsaved.md", kind: .document, content: "Unsaved"))
        XCTAssertEqual(chat.workState, before)
        XCTAssertEqual(store.loadSession(id: session.id)?.workState?.items ?? [], [])
    }

    func testWorkOnlySessionSurvivesSwitchingAndPreservesExistingMetadata() async throws {
        let (root, store, original) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        try chat.createWorkItem(title: "Brief.md", kind: .document, content: "# Hello")
        chat.toggleWorkPaneExpanded()
        chat.createSession()
        XCTAssertNotEqual(chat.currentSessionID, original.id)
        let saved = try XCTUnwrap(store.loadSession(id: original.id))
        XCTAssertEqual(saved.customTitle, original.customTitle)
        XCTAssertEqual(saved.importedSystemPrompt, original.importedSystemPrompt)
        XCTAssertEqual(saved.personalizationSnapshot, original.personalizationSnapshot)
        XCTAssertEqual(saved.workState?.selectedItem?.content, "# Hello")
        XCTAssertEqual(saved.workState?.isExpanded, true)
        chat.selectSession(original.id)
        XCTAssertEqual(chat.workState, saved.workState)
    }

    func testEditsSynchronizeAcrossWindowsAndRespectSessionOwnership() async throws {
        let (root, store, original) = try fixture()
        let hub = PersistedDataChangeHub()
        let activity = InferenceActivityCoordinator()
        let firstID = UUID()
        let first = subject(root, windowID: firstID, hub: hub, activity: activity)
        let second = subject(root, hub: hub, activity: activity)
        try await loaded(first, second)
        try first.createWorkItem(title: "Code", kind: .code, content: "Original")
        let item = try XCTUnwrap(second.workState.selectedItem)
        XCTAssertEqual(first.workState, second.workState)
        let operationID = UUID()
        XCTAssertTrue(activity.begin(resource: .chat(original.id), windowID: firstID, operationID: operationID))
        defer { activity.end(resource: .chat(original.id), operationID: operationID) }
        XCTAssertThrowsError(try second.updateWorkItem(item.id, content: "Blocked", previousContent: "Original"))
        XCTAssertThrowsError(try second.deleteWorkItem(item.id) { _ in
            XCTFail("A chat owned by another window must not trash a file")
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(second.workState.selectedItem?.content, "Original")
        try first.updateWorkItem(item.id, content: "Updated", previousContent: "Original")
        XCTAssertEqual(second.workState.selectedItem?.content, "Updated")
        XCTAssertEqual(store.loadSession(id: original.id)?.workState?.selectedItem?.revision, 2)
    }

    func testFailedSaveDoesNotPublishUnsavedWork() async throws {
        let (root, _, _) = try fixture()
        let chat = subject(root)
        try await loaded(chat)
        let before = chat.workState
        let sessions = root.appendingPathComponent("Chat/Sessions")
        try FileManager.default.removeItem(at: sessions)
        try Data("not a directory".utf8).write(to: sessions)
        XCTAssertThrowsError(try chat.createWorkItem(title: "Unsaved", kind: .document, content: "Do not claim saved"))
        XCTAssertEqual(chat.workState, before)
    }
}
