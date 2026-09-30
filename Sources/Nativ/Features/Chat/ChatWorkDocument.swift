import Foundation

enum ChatWorkDocument {
    static func renderedMarkdown(_ source: String) -> String {
        MathPreprocessor.preprocess(source)
    }

    /// Translate prose, retaining paragraph boundaries and leaving code out of the request.
    static func translationText(_ source: String) -> String {
        func text(_ node: MarkdownNode) -> String {
            switch node.kind {
            case "code_block": return ""
            case "softbreak", "linebreak": return "\n"
            case "text", "code": return node.literal
            case "html_inline": return ""
            case "html_block":
                return node.literal.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            default:
                let separator = ["list", "item", "tasklist", "block_quote", "table", "table_header", "table_row"].contains(node.kind)
                    ? "\n" : ""
                return node.children.map(text).filter { !$0.isEmpty }.joined(separator: separator)
            }
        }
        return MarkdownParser.parse(source).map(text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
