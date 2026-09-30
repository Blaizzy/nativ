import Foundation

/// Shared, session-owned work. Closing a tab never deletes its contents.
struct ChatWorkItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case document, code, website

        var symbol: String {
            switch self {
            case .document: "doc.text"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .website: "globe"
            }
        }
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var content: String
    var url: String?
    var language: String?
    var sourceURL: String?
    var revision = 1
    var updatedBy = "You"

    var canEdit: Bool { url == nil }
}

struct ChatWorkState: Codable, Equatable {
    static let maximumContentBytes = 256_000
    static let maximumItems = 24
    var items: [ChatWorkItem] = []
    var openIDs: [UUID] = []
    var selectedID: UUID?
    var isVisible = false
    var isExpanded: Bool? = false

    var selectedItem: ChatWorkItem? { items.first { $0.id == selectedID } }
    var openItems: [ChatWorkItem] { openIDs.compactMap { id in items.first { $0.id == id } } }

    mutating func openNewTab() {
        selectedID = nil
        isVisible = true
    }

    mutating func open(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        if !openIDs.contains(id) { openIDs.append(id) }
        selectedID = id
        isVisible = true
    }

    mutating func close(_ id: UUID) {
        guard let index = openIDs.firstIndex(of: id) else { return }
        openIDs.remove(at: index)
        if selectedID == id {
            selectedID = openIDs.isEmpty ? nil : openIDs[min(index, openIDs.count - 1)]
        }
    }

    @discardableResult
    mutating func create(
        title: String, kind: ChatWorkItem.Kind, content: String = "",
        url: String? = nil, language: String? = nil, sourceURL: String? = nil, author: String = "You"
    ) throws -> ChatWorkItem {
        guard items.count < Self.maximumItems else {
            throw ChatWorkError.invalid("This chat already has \(Self.maximumItems) work items.")
        }
        let title = try Self.validatedTitle(title)
        try Self.validateContent(content)
        if let url {
            guard kind == .website, content.isEmpty else {
                throw ChatWorkError.invalid("A website needs either a URL or HTML content, not both.")
            }
            _ = try Self.webURL(url)
        }
        let item = ChatWorkItem(
            title: title, kind: kind, content: content, url: url,
            language: language, sourceURL: sourceURL, updatedBy: author
        )
        items.append(item)
        open(item.id)
        return item
    }

    @discardableResult
    mutating func update(
        id: UUID, content: String, expectedRevision: Int,
        title: String? = nil, author: String
    ) throws -> ChatWorkItem {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw ChatWorkError.missingItem
        }
        guard items[index].revision == expectedRevision else {
            throw ChatWorkError.conflict
        }
        guard items[index].canEdit else {
            throw ChatWorkError.invalid("Remote websites are view-only. Create an HTML website to edit its source.")
        }
        try Self.validateContent(content)
        let validatedTitle = try title.map(Self.validatedTitle)
        items[index].content = content
        if let validatedTitle { items[index].title = validatedTitle }
        items[index].revision += 1
        items[index].updatedBy = author
        return items[index]
    }

    static func webURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ChatWorkError.invalid("Enter an http:// or https:// website URL.")
        }
        return url
    }

    /// Resolve text entered by the user; agent navigation still requires an explicit web URL.
    static func addressURL(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ChatWorkError.invalid("Enter a website or a search term.") }
        let host = text.components(separatedBy: "/")[0].components(separatedBy: ":")[0].lowercased()
        let isLocal = host == "localhost" || host == "127.0.0.1" || text.hasPrefix("[::1]")
        if text.contains("://") || (!isLocal && !host.contains(".") && URL(string: text)?.scheme != nil) {
            return try webURL(text)
        }
        if !text.contains(where: { $0.isWhitespace }), isLocal || host.contains(".") {
            return try webURL("\(isLocal ? "http" : "https")://\(text)")
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return try webURL(search.url!.absoluteString)
    }

    private static func validateContent(_ content: String) throws {
        guard content.utf8.count <= maximumContentBytes else {
            throw ChatWorkError.invalid("Work items support up to 256 KB of text.")
        }
    }

    private static func validatedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else {
            throw ChatWorkError.invalid("Use a title between 1 and 160 characters.")
        }
        return trimmed
    }
}

enum ChatWorkError: LocalizedError {
    case invalid(String), missingItem, conflict, unavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .missingItem: "This work item is no longer available in this chat. List the work items again."
        case .conflict: "This item changed since it was read. Read the latest revision before updating it."
        case .unavailable: "The chat work pane is unavailable in this context."
        }
    }
}
