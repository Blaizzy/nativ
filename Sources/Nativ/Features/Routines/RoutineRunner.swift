import Foundation
import NativServerKit

@MainActor
final class RoutineRunner {
    private let model: NativModel
    private let store: RoutineStore
    private let sessionStore: ChatSessionStore

    var onRunCompleted: ((Routine, RoutineRun) -> Void)?

    private struct QueuedRun {
        let routineID: String
        let source: RoutineRunSource
    }

    private var queue: [QueuedRun] = []
    private var activeTask: Task<Void, Never>?
    private var activeRoutineID: String?
    private var isExecuting = false

    init(model: NativModel, store: RoutineStore, sessionStore: ChatSessionStore) {
        self.model = model
        self.store = store
        self.sessionStore = sessionStore
    }

    func run(_ routine: Routine, source: RoutineRunSource) {
        guard store.routine(id: routine.id) != nil else {
            return
        }
        queue.append(QueuedRun(routineID: routine.id, source: source))
        drain()
    }

    func cancel(routineID: String) {
        queue.removeAll { $0.routineID == routineID }
        guard activeRoutineID == routineID else {
            return
        }
        activeTask?.cancel()
    }

    private func drain() {
        guard !isExecuting, !queue.isEmpty else {
            return
        }
        let queuedRun = queue.removeFirst()
        guard let routine = store.routine(id: queuedRun.routineID) else {
            drain()
            return
        }
        isExecuting = true
        activeRoutineID = routine.id
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await execute(routine, source: queuedRun.source)
            guard self.activeRoutineID == routine.id else {
                return
            }
            self.activeTask = nil
            self.activeRoutineID = nil
            self.isExecuting = false
            self.drain()
        }
        activeTask = task
    }

    private func execute(_ routine: Routine, source: RoutineRunSource) async {
        guard !Task.isCancelled,
              store.routine(id: routine.id) != nil
        else {
            return
        }

        var run = RoutineRun(routineID: routine.id, source: source, status: .running)
        store.recordRun(run)

        if !model.isRunning {
            model.startServer()
        }
        await waitForServer()
        guard !Task.isCancelled,
              store.routine(id: routine.id) != nil
        else {
            return
        }

        guard let baseURL = model.activeServerBaseURL else {
            finish(&run, routine: routine, status: .failed, summary: "The Nativ server isn’t running.")
            return
        }

        let settings = model.settings.normalized()
        var messages: [MLXChatMessage] = []
        if let systemPrompt = systemPrompt(for: routine) {
            messages.append(MLXChatMessage(role: "system", content: systemPrompt))
        }
        messages.append(MLXChatMessage(role: "user", content: routine.instructions))

        let client = NativChatClient(baseURL: baseURL, apiKey: settings.serverAPIKey)
        let request = MLXChatCompletionRequest(
            model: routine.modelID,
            messages: messages,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP
        )

        do {
            let completion = try await client.completeChat(request)
            guard !Task.isCancelled,
                  store.routine(id: routine.id) != nil
            else {
                return
            }
            guard let sessionID = appendRun(routine: routine, completion: completion) else {
                finish(
                    &run,
                    routine: routine,
                    status: .failed,
                    summary: "The routine source chat no longer exists."
                )
                return
            }
            NotificationCenter.default.post(name: .routineDidSaveChatSession, object: nil)
            run.sessionID = sessionID
            finish(&run, routine: routine, status: .succeeded, summary: Self.summarize(completion.content))
        } catch is CancellationError {
            finish(&run, routine: routine, status: .cancelled, summary: "Routine run cancelled.")
        } catch let error as URLError where error.code == .cancelled {
            finish(&run, routine: routine, status: .cancelled, summary: "Routine run cancelled.")
        } catch {
            finish(&run, routine: routine, status: .failed, summary: error.localizedDescription)
        }
    }

    private func appendRun(routine: Routine, completion: MLXChatCompletion) -> UUID? {
        let userMessage = ChatTranscriptMessage(
            role: .user,
            content: routine.instructions
        )
        let assistantMessage = ChatTranscriptMessage(
            role: .assistant,
            content: completion.content,
            reasoningContent: completion.reasoningContent ?? "",
            modelID: routine.modelID
        )
        guard let sessionID = routine.sourceSessionID,
              var session = sessionStore.loadSession(id: sessionID)
        else {
            return nil
        }
        session.messages.append(userMessage)
        session.messages.append(assistantMessage)
        session.updatedAt = Date()
        sessionStore.saveSession(session)
        return sessionID
    }

    private func finish(
        _ run: inout RoutineRun,
        routine: Routine,
        status: RoutineRunStatus,
        summary: String
    ) {
        run.status = status
        run.finishedAt = Date()
        run.resultSummary = summary
        store.recordRun(run)
        onRunCompleted?(routine, run)
    }

    private func waitForServer(timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.activeServerBaseURL == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let baseURL = model.activeServerBaseURL else {
            return
        }
        let healthURL = baseURL.appendingPathComponent("v1/models")
        while Date() < deadline {
            if await Self.isReachable(healthURL) {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private static func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func systemPrompt(for routine: Routine) -> String? {
        guard let kitID = routine.kitID,
              let kit = NativKit.all.first(where: { $0.id == kitID })
        else {
            return nil
        }
        let instructions = kit.skills
            .filter(\.isEnabled)
            .map(\.instructions)
            .filter { !$0.isEmpty }
        return instructions.isEmpty ? nil : instructions.joined(separator: "\n\n")
    }

    private static func summarize(_ content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.count > 140 ? String(firstLine.prefix(139)) + "…" : firstLine
    }
}

extension Notification.Name {
    static let routineDidSaveChatSession = Notification.Name("RoutineDidSaveChatSession")
}
