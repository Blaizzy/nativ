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
            let evidence = ProcessInfo.processInfo.environment["CHAT_WORK_BENCHMARK_EVIDENCE"] == "1"
                ? ChatBrowserEvidence.context(messages: messages, maximumBytes: min(8192, maximumBytes)) : nil
            let enabled = ProcessInfo.processInfo.environment["CHAT_WORK_BENCHMARK_EVIDENCE"] == "1"
            return String(decoding: try JSONEncoder().encode([
                "text": evidence ?? "",
                "missing_pages": enabled ? ChatBrowserEvidence.missingPageInstruction(messages: messages) ?? "" : "",
                "stalled_search": enabled ? ChatBrowserEvidence.stalledSearchInstruction(messages: messages) ?? "" : "",
            ]), as: UTF8.self)
        }
        guard input.name == "chat_work" else { throw ChatWorkError.invalid("Use chat_work.") }
        var request = try JSONDecoder().decode(ChatWorkRequest.self, from: arguments).resolvingElementOpen()
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
        return ChatBrowsingBudget.bound(text, maximumBytes: maximumBytes)
    }
}
