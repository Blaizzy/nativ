import Foundation

enum ChatWorkDocument {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    static let sourceLanguages = [
        "swift": "swift", "py": "python", "js": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "json": "json", "css": "css", "scss": "scss",
        "sh": "bash", "bash": "bash", "zsh": "bash", "html": "html", "htm": "html",
        "java": "java", "kt": "kotlin", "c": "c", "cpp": "cpp", "cc": "cpp", "h": "c",
        "hpp": "cpp", "rb": "ruby", "go": "go", "rs": "rust", "php": "php",
        "xml": "xml", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        "txt": "text", "text": "text", "log": "text", "csv": "text", "tsv": "text"
    ]

    static func sourcePreview(_ source: String, language: String) -> String {
        let fence = String(repeating: "`", count: max(3, (source.components(separatedBy: .newlines)
            .map { $0.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0 == "`" }).count }.max() ?? 0) + 1))
        return "\(fence)\(language)\n\(source)\n\(fence)"
    }

    static func filePreview(_ source: String, filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext) ? renderedMarkdown(source)
            : sourcePreview(source, language: sourceLanguages[ext] ?? "text")
    }

    static func renderedMarkdown(_ source: String) -> String {
        MathPreprocessor.preprocess(source)
    }

    /// Copy readable Markdown text, including code blocks and table cell boundaries.
    static func plainText(_ source: String) -> String {
        func text(_ node: MarkdownNode) -> String {
            switch node.kind {
            case "softbreak", "linebreak": return "\n"
            case "text", "code", "code_block": return node.literal
            case "table_header", "table_row": return node.children.map(text).joined(separator: "\t")
            case "tasklist":
                return (node.checked == true ? "☑ " : "☐ ") + node.children.map(text).joined(separator: "\n")
            case "list":
                return node.children.enumerated().map { offset, child in
                    let marker = child.checked != nil ? "" : node.ordered ? "\(node.start + offset). " : "• "
                    return marker + text(child)
                }.joined(separator: "\n")
            case "html_inline": return ""
            case "html_block":
                return node.literal.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            default:
                if node.children.isEmpty { return node.literal }
                let separator = ["item", "block_quote", "table"].contains(node.kind) ? "\n" : ""
                return node.children.map(text).filter { !$0.isEmpty }.joined(separator: separator)
            }
        }
        return MarkdownParser.parse(source).map(text).filter { !$0.isEmpty }.joined(separator: "\n\n")
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
