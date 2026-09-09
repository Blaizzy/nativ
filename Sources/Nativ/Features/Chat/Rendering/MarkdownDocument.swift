import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// A view-independent GFM tree. IDs are structural paths, never hashes of changing text.
struct MarkdownNode: Sendable {
    let kind: String
    var literal = ""
    var destination = ""
    var level = 0
    var ordered = false
    var start = 1
    var tight = false
    var checked: Bool?
    var alignments: [UInt8] = []
    var children: [MarkdownNode] = []
}

enum MarkdownParser {
    // Swift's static initialization registers the shared extension registry once.
    private static let registerExtensions: Void = cmark_gfm_core_extensions_ensure_registered()

    static func parse(_ markdown: String) -> [MarkdownNode] {
        _ = registerExtensions
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return [MarkdownNode(kind: "paragraph", literal: markdown)]
        }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
        guard let document = cmark_parser_finish(parser) else {
            return [MarkdownNode(kind: "paragraph", literal: markdown)]
        }
        defer { cmark_node_free(document) }
        return children(of: document)
    }

    private static func children(of parent: UnsafeMutablePointer<cmark_node>)
        -> [MarkdownNode]
    {
        var result: [MarkdownNode] = []
        var cursor = cmark_node_first_child(parent)
        while let node = cursor {
            let kind = string(cmark_node_get_type_string(node))
            var value = MarkdownNode(kind: kind)
            value.literal = string(cmark_node_get_literal(node))
            value.destination = string(cmark_node_get_url(node))
            if kind == "heading" { value.level = Int(cmark_node_get_heading_level(node)) }
            if kind == "code_block" { value.destination = string(cmark_node_get_fence_info(node)) }
            if kind == "list" {
                value.ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
                value.start = Int(cmark_node_get_list_start(node))
                value.tight = cmark_node_get_list_tight(node) != 0
            }
            if kind == "tasklist" {
                value.checked = cmark_gfm_extensions_get_tasklist_item_checked(node)
            }
            if kind == "table", let alignments = cmark_gfm_extensions_get_table_alignments(node) {
                value.alignments = Array(
                    UnsafeBufferPointer(
                        start: alignments, count: Int(cmark_gfm_extensions_get_table_columns(node)))
                )
            }
            value.children = children(of: node)
            result.append(value)
            cursor = cmark_node_next(node)
        }
        return result
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map(String.init(cString:)) ?? ""
    }
}
