// Appended only by build_helper.py to a temporary Main.swift during benchmark builds.
// The installed app and ordinary builds have no benchmark command-line entry point.
import WebKit

@MainActor
private final class ChatWorkBenchmarkBridge {
    private var state = ChatWorkState()
    private let sessionID = UUID()
    private let pool = ChatWorkBrowserPool(profile: ChatWorkBrowserProfile(dataStore: .nonPersistent()))

    static func run() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let bridge = ChatWorkBenchmarkBridge()
        DispatchQueue.global().async {
            while let line = readLine() {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    do { print(try await bridge.handle(Data(line.utf8))) }
                    catch { print(ChatWorkToolRegistry.failurePayload(error: error)) }
                    fflush(stdout)
                    done.signal()
                }
                done.wait()
            }
            Task { @MainActor in exit(EXIT_SUCCESS) }
        }
        RunLoop.main.run()
    }

    private func handle(_ data: Data) async throws -> String {
        struct Input: Decodable { var name: String; var arguments: MLXJSONValue?; var context: Int? }
        let input = try JSONDecoder().decode(Input.self, from: data)
        let maximumBytes = ChatBrowsingBudget.maximumBytes(context: input.context ?? 8192)
        let arguments = try JSONEncoder().encode(input.arguments ?? .object([:]))
        if input.name == "tools" {
            let definitions = String(decoding: try JSONEncoder().encode([ChatWorkToolRegistry.definition]), as: UTF8.self)
            let prompt = String(decoding: try JSONEncoder().encode(ChatWorkToolRegistry.sessionPrompt), as: UTF8.self)
            let finalPrompt = String(decoding: try JSONEncoder().encode(ChatToolRoundGate.finalAnswerPrompt), as: UTF8.self)
            return "{\"tools\":\(definitions),\"session_prompt\":\(prompt),\"final_answer_prompt\":\(finalPrompt)}"
        }
        if input.name == "context" {
            struct Context: Decodable { var messages: [MLXChatMessage] }
            let messages = try JSONDecoder().decode(Context.self, from: arguments).messages
            let enabled = ProcessInfo.processInfo.environment["CHAT_WORK_BENCHMARK_EVIDENCE"] == "1"
            var result: [String: MLXJSONValue] = [
                "text": .string(""),
                "missing_pages": .string(enabled ? ChatBrowserEvidence.missingPageInstruction(messages: messages) ?? "" : ""),
                "stalled_search": .string(enabled ? ChatBrowserEvidence.stalledSearchInstruction(messages: messages) ?? "" : ""),
            ]
            if enabled, let context = ChatBrowserEvidence.recoveryContext(messages: messages, maximumBytes: min(8192, maximumBytes)) {
                result["tool_result_context"] = try MLXJSONValue(jsonData: JSONEncoder().encode(context))
            }
            return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        }
        guard input.name == "chat_work" else { throw ChatWorkError.invalid("Use chat_work.") }
        var request = try JSONDecoder().decode(ChatWorkRequest.self, from: arguments)
        let prioritizeText = [.open, .navigate, .search, .back, .forward].contains(request.action)
        let source = request.action == .open ? request.elementID.flatMap { pool.sourceLink(for: $0, sessionID: sessionID) } : nil
        if let source, let id = request.id, id != source.id { throw ChatWorkError.invalid("Source result belongs to another tab.") }
        request = try request.resolvingElementOpen(sourceURL: source?.url)
        if let source { request.id = source.id }
        if request.action == .list { return try state.itemListJSON() }
        if request.action == .read {
            guard request.id != nil else { throw ChatWorkError.invalid("read requires id.") }
            request.action = .inspect
        }
        if request.action == .create, request.kind == .website, request.url != nil {
            _ = try state.execute(request)
            request = ChatWorkRequest(action: .inspect, id: state.selectedID)
        }
        guard request.action.isBrowserAction || request.action == .open else { throw ChatWorkError.unavailable }
        if request.id == nil, let elementID = request.elementID {
            request.id = pool.itemID(for: elementID, sessionID: sessionID)
        }
        let item = try state.browserItem(for: request)
        request.id = item.id
        let browser = pool.browser(for: item, sessionID: sessionID)
        browser.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        browser.onNavigate = { [weak self] url in
            guard let self, let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
            state.items[index].url = url
        }
        let snapshot = try await browser.execute(request)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), as: UTF8.self)
        return ChatBrowsingBudget.bound(text, maximumBytes: maximumBytes, prioritizeText: prioritizeText)
    }
}
