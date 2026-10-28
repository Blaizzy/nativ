import Foundation

/// Bound saved tool results once, so later replay uses the same transcript prefix.
enum ChatBrowsingBudget {
    static func maximumBytes(context: Int) -> Int {
        min(16_000, max(512, (context > 0 ? context : 8_192) / 2))
    }

    static func bound(_ content: String, maximumBytes: Int, prioritizeText: Bool = false) -> String {
        guard content.utf8.count > maximumBytes,
              let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return content }
        var textLimit = max(64, maximumBytes / 2)
        // Research needs the readable passage before navigation chrome. Start
        // with a few controls so a large menu cannot force text down to a heading.
        var elementLimit = prioritizeText ? (object["source_kind"] as? String == "search" ? 6 : 2) : 24
        for _ in 0..<12 {
            var bounded = reduce(object, textLimit: textLimit, elementLimit: elementLimit) as? [String: Any] ?? object
            bounded["truncated"] = true
            bounded["omission_notice"] = "Page excerpts were shortened to fit the context; some page content and controls were omitted."
            guard let encoded = try? JSONSerialization.data(withJSONObject: bounded, options: [.sortedKeys, .withoutEscapingSlashes]) else { return content }
            if encoded.count <= maximumBytes {
                return String(decoding: encoded, as: UTF8.self)
            }
            textLimit = max(32, textLimit / 2)
            elementLimit /= 2
        }
        return #"{"truncated":true,"omission_notice":"Result metadata exceeds this context budget. Read one URL at a time with a focused query."}"#
    }

    private static func reduce(_ value: Any, textLimit: Int, elementLimit: Int, key: String = "") -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = reduce(pair.value, textLimit: textLimit, elementLimit: elementLimit, key: pair.key)
            }
        }
        if let values = value as? [Any] {
            let selected = ["elements", "results"].contains(key) ? Array(values.prefix(elementLimit)) : values
            return selected.map { reduce($0, textLimit: textLimit, elementLimit: elementLimit, key: key) }
        }
        if let text = value as? String, ["text", "content", "snippet", "value", "label", "title"].contains(key), text.utf8.count > textLimit {
            let prefix = String(decoding: text.utf8.prefix(max(0, textLimit - 24)), as: UTF8.self)
            return prefix + "\n[Excerpt shortened]"
        }
        return value
    }
}
