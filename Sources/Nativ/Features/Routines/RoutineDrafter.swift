import Foundation
import NativServerKit

@MainActor
enum RoutineDrafter {
    private struct DraftResult: Decodable {
        var name: String?
        var instructions: String?
        var hour: Int?
        var minute: Int?
        var weekdays: [Int]?
    }

    static func draft(
        description: String,
        designerModelID: String,
        model: NativModel
    ) async -> Routine? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !designerModelID.isEmpty else {
            return nil
        }

        if !model.isRunning {
            model.startServer()
        }
        let deadline = Date().addingTimeInterval(90)
        while model.activeServerBaseURL == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let baseURL = model.activeServerBaseURL else {
            return nil
        }

        let settings = model.settings.normalized()
        let system = """
        You design automation routines for a local AI app. Given the user's request, \
        respond with ONLY a JSON object and nothing else, using these keys:
        "name": a short title, at most six words.
        "instructions": a clear, self-contained prompt the routine runs each time.
        "hour": integer 0-23 for the daily run time.
        "minute": integer 0-59.
        "weekdays": array of integers 1-7 (1 = Sunday), or [] for every day.
        """
        let messages = [
            MLXChatMessage(role: "system", content: system),
            MLXChatMessage(role: "user", content: trimmed),
        ]
        let client = NativChatClient(baseURL: baseURL, apiKey: settings.serverAPIKey)
        let request = MLXChatCompletionRequest(
            model: designerModelID,
            messages: messages,
            maxTokens: settings.maxTokens,
            temperature: 0.2,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP
        )

        guard let completion = try? await client.completeChat(request),
              let json = extractJSONObject(from: completion.content),
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(DraftResult.self, from: data)
        else {
            return nil
        }

        let schedule = RoutineSchedule(
            weekdays: Set(result.weekdays ?? []),
            hour: result.hour ?? 9,
            minute: result.minute ?? 0
        )
        return Routine(
            name: result.name ?? "New routine",
            instructions: result.instructions ?? trimmed,
            modelID: designerModelID,
            triggerKind: .schedule,
            schedule: schedule
        )
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end
        else {
            return nil
        }
        return String(text[start...end])
    }
}
