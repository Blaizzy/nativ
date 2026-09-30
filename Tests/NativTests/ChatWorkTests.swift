import XCTest
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
        let session = ChatSession(id: UUID(), title: "Work", createdAt: Date(), updatedAt: Date(), messages: [], workState: state)
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)
        XCTAssertEqual(decoded.workState, state)
        XCTAssertEqual(decoded.workState?.selectedID, item.id)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

    private func json(_ value: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }
}

@MainActor
final class ChatWorkSessionTests: XCTestCase {
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
