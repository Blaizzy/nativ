import Foundation
import NativServerKit

/// Rebuild from saved tool receipts, never from a model-generated handoff. This is
/// transient source material: changing it must not invalidate the conversation prefix.
enum ChatBrowserEvidence {
    static func recoveryContext(messages: [MLXChatMessage], maximumBytes: Int) -> MLXToolResultContext? {
        guard maximumBytes >= 512 else { return nil }
        let entries = sourcePages(messages: messages).suffix(64).compactMap { source -> MLXToolResultContext.Entry? in
            guard let id = source.callID, !id.isEmpty else { return nil }
            return .init(toolCallID: id, text: "Source: \(source.url)\nExcerpt: \(source.text)")
        }
        return entries.isEmpty ? nil : .init(entries: entries, maxBytes: min(8192, maximumBytes))
    }

    private static func sourcePages(messages: [MLXChatMessage]) -> [(url: String, text: String, callID: String?)] {
        guard let turn = messages.lastIndex(where: { $0.role == "user" }) else { return [] }
        var sources: [(url: String, text: String, callID: String?)] = []
        var indices: [String: Int] = [:]
        for message in messages.dropFirst(turn + 1) where message.role == "tool" && message.name == "chat_work" {
            guard let text = message.textContent,
                  let result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  result["ok"] as? Bool != false, result["error"] == nil,
                  !["blocked", "insufficient_text", "preview", "media_metadata"].contains(result["page_status"] as? String ?? ""),
                  (result["http_status"] as? Int ?? 200) < 400,
                  result["editable"] as? Bool != true, result["local_page_url"] == nil,
                  result["kind"] as? String == "website", result["source_kind"] as? String != "search",
                  let rawURL = result["url"] as? String,
                  var url = URLComponents(string: rawURL), ["http", "https"].contains(url.scheme ?? ""),
                  let host = url.host, !host.isEmpty,
                  !isSearchOrChallenge(url),
                  let body = result["text"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let title = (result["title"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if isBlocked(title: title, body: body) { continue }
            url.fragment = nil
            // Completed Reddit challenges retain per-visit tokens on the same page.
            let challengeKeys: Set<String> = ["js_challenge", "jsc_token", "jsc_orig_r", "solution"]
            let reddit = host == "reddit.com" || host.hasSuffix(".reddit.com")
            url.queryItems = url.queryItems?.filter { $0.name != "js_challenge" && !(reddit && challengeKeys.contains($0.name)) }
            if url.queryItems?.isEmpty == true { url.queryItems = nil }
            guard let key = url.string else { continue }
            // Exact excerpts keep numbers/names intact. No inferred facts or summarization.
            let excerpt = prefix(body.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 800)
            if let index = indices[key] {
                sources[index].text = excerpt
                sources[index].callID = message.toolCallID
            } else {
                indices[key] = sources.count
                sources.append((key, excerpt, message.toolCallID))
            }
        }
        return sources
    }

    static func missingPageInstruction(messages: [MLXChatMessage]) -> String? {
        guard let task = messages.last(where: { $0.role == "user" })?.textContent,
              let expression = try? NSRegularExpression(pattern: #"(?i)\b(?:read|visit|open|consult|review)\s+(?:at\s+least\s+|all\s+)?(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(?:linked\b|(?:(?:different|distinct|separate|source|web)\s+)*(?:pages|sources|websites|sites)\b)"#),
              let match = expression.firstMatch(in: task, range: NSRange(task.startIndex..., in: task)),
              let range = Range(match.range(at: 1), in: task),
              let commandRange = Range(match.range, in: task),
              let turn = messages.lastIndex(where: { $0.role == "user" }),
              messages.dropFirst(turn + 1).contains(where: { $0.role == "tool" && $0.name == "chat_work" }) else { return nil }
        let prefix = task[..<commandRange.lowerBound].suffix(32).lowercased()
        if prefix.range(of: #"(?:do not|don't|no need to|without)\s*$"#, options: .regularExpression) != nil { return nil }
        let number = String(task[range]).lowercased()
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        let requested = Int(number) ?? words.firstIndex(of: number).map { $0 + 1 } ?? 0
        var pages = sourcePages(messages: messages)
        let linked = task[commandRange].lowercased().hasSuffix("linked")
        if linked, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let parents = Set(detector.matches(in: task, range: NSRange(task.startIndex..., in: task)).compactMap { match -> String? in
                guard var url = match.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
                      ["http", "https"].contains(url.scheme ?? "") else { return nil }
                url.fragment = nil
                return url.string
            })
            // An explicitly supplied index is a starting point, not one of its children.
            pages.removeAll { parents.contains($0.url) }
        }
        let observed = pages.count
        guard requested > observed else { return nil }
        let scope = linked ? "linked pages (excluding the supplied index URLs)" : "distinct pages"
        return "The user requested reading \(requested) \(scope). Only \(observed) distinct readable page receipts are available; relevance still needs checking. Continue the authorized research using chat_work. Follow a search result's open action to read its page. Search snippets, error pages, login screens and repeated visits do not satisfy the request. If human input is required or sources remain unavailable, state the blocker and incomplete source count honestly."
    }

    static func stalledSearchInstruction(messages: [MLXChatMessage]) -> String? {
        guard let turn = messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        let receipts = messages.dropFirst(turn + 1).filter { $0.role == "tool" && $0.name == "chat_work" }.suffix(3)
        guard receipts.count == 3, receipts.allSatisfy({ message in
            guard let text = message.textContent,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return false }
            return object["source_kind"] as? String == "search"
        }) else { return nil }
        return "The last three browser actions returned search results without reading a source page. Follow one of the current results using its open action before searching again. If none is relevant, explain the obstacle instead of repeating the same search."
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var output = "", count = 0
        for character in text {
            let size = String(character).utf8.count
            if count + size > bytes { break }
            output.append(character)
            count += size
        }
        return output
    }

    private static func isSearchOrChallenge(_ url: URLComponents) -> Bool {
        let host = (url.host ?? "").lowercased()
        let google = host.range(of: #"(^|\.)google\.[a-z.]+$"#, options: .regularExpression) != nil
        return (google && (["/search", "/goto", "/url"].contains(url.path) || url.path.hasPrefix("/sorry")))
            || host.hasPrefix("consent.google.") || host == "consent.youtube.com"
    }

    private static func isBlocked(title: String, body: String) -> Bool {
        if ["access denied", "page not found", "just a moment...", "are you a robot?"].contains(title) { return true }
        let start = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600).lowercased()
        return start.range(of: #"^(?:404\b|page not found\b|access denied\b|just a moment\b|verify you are human\b)"#, options: .regularExpression) != nil
            || (start.contains("log in to facebook") && start.contains("password"))
            || (start.contains("allow the use of cookies") && start.contains("facebook"))
    }
}
