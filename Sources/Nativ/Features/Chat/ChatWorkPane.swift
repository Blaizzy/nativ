import AppKit
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ChatWorkPane: View {
    @ObservedObject var chat: ChatViewModel
    let onRequestEdit: (ChatWorkFeedback, String) async throws -> Void
    @ObservedObject private var browserProfile = ChatWorkBrowserProfile.shared
    @Environment(\.controlPanelIsFullScreen) private var isFullScreen
    @Environment(\.controlPanelIsSidebarVisible) private var isSidebarVisible
    @State private var sourceIDs: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var selectedText = ""
    @State private var translationText = ""
    @State private var showsTranslation = false
    @State private var preparesTranslation = false
    @State private var confirmsClearWebsiteData = false
    @State private var showsFiles = false
    @State private var renameTarget: ChatWorkItem?
    @State private var renameSessionID: UUID?
    @State private var fileName = ""
    @State private var fileSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let item = chat.workState.selectedItem {
                if item.kind == .terminal, let sessionID = chat.currentSessionID {
                    ChatWorkTerminalPane(session: chat.workTerminal(for: item, sessionID: sessionID)) {
                        chat.restartWorkTerminal(item.id)
                    }
                    .id(item.id)
                } else {
                    if item.resolvedKind == .website, let sessionID = chat.currentSessionID {
                        ChatWorkBrowserToolbar(browser: chat.workBrowser(for: item, sessionID: sessionID),
                                               isShowingSource: sourceIDs.contains(item.id), onAnnotate: { annotation in
                            guard chat.currentSessionID == sessionID, chat.workState.selectedID == item.id else { return }
                            addFeedback(for: item, annotation: annotation)
                        }, onAnnotationError: { errorMessage = $0 }) {
                            browserPageMenu(item)
                        }
                        .disabled(browserProfile.isClearingWebsiteData)
                    } else {
                        itemToolbar(item)
                    }
                    Divider()
                    itemContent(item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(item.kind == .terminal ? "Terminal in this chat" : "Saved in this chat")
                    Spacer()
                    Text("\(item.updatedBy) · Revision \(item.revision)")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else {
                if showsFiles {
                    filesPage
                } else {
                    newTabToolbar
                    newTabPage
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: chat.workState.selectedID) { _, _ in
            selectedText = ""
            showsTranslation = false
            if chat.workState.selectedID != nil { showsFiles = false }
        }
        .onChange(of: chat.currentSessionID) { _, _ in
            selectedText = ""
            sourceIDs = []
            showsTranslation = false
            showsFiles = false
            renameTarget = nil
            fileSearch = ""
            refreshFiles()
        }
        .onAppear { refreshFiles() }
        .onChange(of: chat.isPreparingCurrentWorktree) { _, preparing in
            if !preparing { refreshFiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshFiles()
        }
        .alert("Work pane", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Rename file", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }
        ), presenting: renameTarget) { item in
            TextField("File name", text: $fileName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard chat.currentSessionID == renameSessionID else { return }
                do { try chat.renameWorkItem(item.id, name: fileName, previousTitle: item.title) }
                catch { errorMessage = error.localizedDescription }
            }
            .disabled(fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Clear website data?", isPresented: $confirmsClearWebsiteData,
                            titleVisibility: .visible) {
            Button("Clear website data", role: .destructive) {
                Task { await browserProfile.clearWebsiteData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cookies, website storage, and caches for all browser tabs in this app and signs you out of websites. Open pages will reload. Chats and documents are kept.")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(chat.workState.openItems) { item in
                            workTab(title: item.title, symbol: item.resolvedKind.symbol,
                                    isSelected: chat.workState.selectedID == item.id,
                                    select: { chat.openWorkItem(item.id) },
                                    close: { chat.closeWorkItem(item.id) })
                                .contextMenu { fileLocationActions(item) }
                                .id(item.id.uuidString)
                        }
                        if chat.workState.selectedItem == nil {
                            workTab(title: showsFiles ? "Files" : "New tab", symbol: showsFiles ? "folder" : "globe", isSelected: true,
                                    select: {}, close: closeNewTab)
                                .id("new")
                        }
                        Button { showsFiles = false; chat.openWorkNewTab() } label: {
                            Image(systemName: "plus").frame(width: 28, height: 28)
                        }
                        .help("New tab")
                        .accessibilityLabel("New tab")
                        .id("add")
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: chat.workState.selectedID) { _, id in
                    proxy.scrollTo(id?.uuidString ?? "new", anchor: .trailing)
                }
            }
            Button { chat.toggleWorkPaneExpanded() } label: {
                Image(systemName: chat.workState.isExpanded == true
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 28, height: 28)
            }
            .help(chat.workState.isExpanded == true ? "Enter split view" : "Enter full view")
            .accessibilityLabel(chat.workState.isExpanded == true ? "Enter split view" : "Enter full view")
            Button { chat.setWorkPaneVisible(false) } label: {
                Image(systemName: chat.workState.isWorkOnLeft == true ? "sidebar.left" : "sidebar.right")
                    .frame(width: 28, height: 28)
            }
            .help("Hide work pane")
            .accessibilityLabel("Hide work pane")
            .keyboardShortcut("b", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.leading, (chat.workState.isExpanded == true || chat.workState.isWorkOnLeft == true) && !isSidebarVisible
                 ? (isFullScreen ? ControlPanelLayout.topControlsLeadingPaddingFullScreen
                    : ControlPanelLayout.topControlsLeadingPadding) + ControlPanelLayout.topControlSize
                 : 0)
        .frame(height: 40)
        .background(Color.primary.opacity(0.035))
    }

    private func workTab(title: String, symbol: String, isSelected: Bool,
                         select: @escaping () -> Void, close: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button(action: select) {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
                    .frame(minWidth: 80, maxWidth: 170, alignment: .leading)
                    .padding(.leading, 10)
                    .frame(height: 28)
                    .contentShape(.rect)
            }
            .help(title)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 24, height: 28)
                    .contentShape(.rect)
            }
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .background(isSelected ? Color.primary.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func closeNewTab() {
        if let last = chat.workState.openIDs.last { chat.openWorkItem(last) }
        else { chat.setWorkPaneVisible(false) }
    }

    private var newTabToolbar: some View {
        HStack(spacing: 8) {
            ChatWorkNavigationButtons()
            ChatWorkAddressField(address: "", onSubmit: openWebsite)
            creationMenu
        }
        .padding(8)
    }

    private var creationMenu: some View {
        Menu {
            Button("Files", systemImage: "folder") { openFiles() }
            Divider()
            Button("New document", systemImage: "doc.text") { newDocument() }
            Button("New HTML page", systemImage: "globe") { newHTML() }
            Button("New terminal", systemImage: "terminal") { newTerminal() }
            Divider()
            Button("Import file", systemImage: "folder") { importFile() }
        } label: {
            Image(systemName: "ellipsis").frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More work pane actions")
        .accessibilityLabel("More work pane actions")
    }

    private var newTabPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("Tools")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 8)], spacing: 8) {
                        toolCard("Terminal", symbol: "terminal", action: newTerminal)
                        toolCard("Document", symbol: "doc.text", action: newDocument)
                        toolCard("Website", symbol: "globe", action: newHTML)
                        toolCard("Files", symbol: "folder", action: openFiles)
                    }
                }
                if !chat.workState.items.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Suggested")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                            ForEach(Array(chat.workState.items.suffix(4).reversed())) { item in
                                Button { chat.openWorkItem(item.id) } label: {
                                    VStack(spacing: 16) {
                                        Image(systemName: item.resolvedKind.symbol)
                                            .font(.system(size: 25, weight: .light))
                                            .foregroundStyle(item.resolvedKind == .code ? Color.mint : .secondary)
                                            .frame(height: 34)
                                        Text(item.title).font(.system(size: 12)).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                                    .padding(.horizontal, 8)
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(ChatWorkCardStyle())
                                .help(item.title)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Recents")
                        VStack(spacing: 0) {
                            ForEach(chat.workState.items.reversed()) { item in
                                Button { chat.openWorkItem(item.id) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: item.resolvedKind.symbol)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 30, height: 30)
                                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).lineLimit(1)
                                            Text(itemSubtitle(item)).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                                    }
                                    .font(.system(size: 12))
                                    .padding(10)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(ChatWorkCardStyle())
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your work, alongside your chat").font(.system(size: 13, weight: .medium))
                        Text("Open a terminal, create a document, or open a website above. Work you and your agent create will appear here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }

    private func toolCard(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: title == "Files" ? "arrow.up.right" : "plus")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(ChatWorkCardStyle())
        .help(title == "Files" ? "Browse files created in this chat" : "Create a \(title.lowercased())")
    }

    private var filesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { showsFiles = false } label: { Image(systemName: "arrow.left") }
                    .help("Back to new tab").accessibilityLabel("Back to new tab")
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search files", text: $fileSearch)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search files by name or extension")
                    if !fileSearch.isEmpty {
                        Button { fileSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .help("Clear search").accessibilityLabel("Clear file search")
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                Menu {
                    Button("Import", systemImage: "square.and.arrow.down", action: importFile)
                    Button("Refresh files", systemImage: "arrow.clockwise", action: refreshFiles)
                    if let directory = chat.workFilesDirectory {
                        Divider()
                        Button("Copy folder path", systemImage: "doc.on.doc") { copyWorkText(directory.path) }
                        Button("Show folder in Finder", systemImage: "folder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
                        }
                    }
                } label: {
                    Image(nsImage: Self.pageMenuIcon).frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Files options").accessibilityLabel("Files options")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(16)
            Divider()
            let allFiles = chat.workState.items.filter(\.canEdit)
                .sorted { $0.storedFilename.localizedStandardCompare($1.storedFilename) == .orderedAscending }
            let query = fileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let files = allFiles.filter { query.isEmpty || $0.storedFilename.localizedStandardContains(query) }
            if allFiles.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "folder", description:
                    Text("Documents, code, and HTML pages created in this chat appear here. You can also import a file."))
            } else if files.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files) { item in
                            Button { chat.openWorkItem(item.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.resolvedKind.symbol).foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.storedFilename).lineLimit(1)
                                        Text(itemSubtitle(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12).contentShape(.rect)
                            }
                            .buttonStyle(ChatWorkCardStyle())
                            .help("Open \(item.storedFilename) in the side pane")
                            .contextMenu { fileLocationActions(item) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func fileLocationActions(_ item: ChatWorkItem) -> some View {
        if let url = chat.workFileURL(for: item) {
            Button("Add to chat", systemImage: "text.bubble") { addFeedback(for: item) }
            Divider()
            Button("Rename…", systemImage: "pencil") { beginRenaming(item) }
            Divider()
            Button("Copy file path", systemImage: "doc.on.doc") { copyWorkText(url.path) }
            revealFileButton(item)
            Divider()
            deleteFileButton(item)
        }
    }

    @ViewBuilder
    private func revealFileButton(_ item: ChatWorkItem) -> some View {
        if let url = chat.workFileURL(for: item) {
            Button("Show in Finder", systemImage: "folder") {
                do {
                    try chat.refreshWorkFiles()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func deleteFileButton(_ item: ChatWorkItem) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            do {
                try chat.deleteWorkItem(item.id)
                sourceIDs.remove(item.id)
            } catch { errorMessage = error.localizedDescription }
        }
        .help("Move this file to Trash and remove it from the chat")
    }

    private func beginRenaming(_ item: ChatWorkItem) {
        renameSessionID = chat.currentSessionID
        fileName = item.storedFilename
        renameTarget = item
    }

    private func refreshFiles() {
        guard chat.currentSessionID != nil else { return }
        do { try chat.refreshWorkFiles() }
        catch { errorMessage = error.localizedDescription }
    }

    private func openFiles() {
        do {
            try chat.refreshWorkFiles()
            chat.openWorkNewTab()
            showsFiles = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func itemSubtitle(_ item: ChatWorkItem) -> String {
        if let address = item.url, let host = URL(string: address)?.host { return host }
        switch item.resolvedKind {
        case .document: return "Document"
        case .code: return item.language.map { "Code · \($0)" } ?? "Code"
        case .website: return "Website"
        case .terminal: return item.terminalWorkingDirectory ?? "Terminal"
        }
    }

    private func newDocument() { create(title: "Untitled.md", kind: .document, content: "# Untitled\n\n") }
    private func newTerminal() {
        do {
            let count = chat.workState.items.filter { $0.kind == .terminal && $0.terminalCommand == nil }.count
            try chat.createWorkItem(title: count == 0 ? "Terminal" : "Terminal \(count + 1)", kind: .terminal)
        } catch { errorMessage = error.localizedDescription }
    }
    private func newHTML() {
        create(title: "index.html", kind: .website, content: """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Untitled</title></head>
            <body><h1>Build something together.</h1></body>
            </html>
            """)
    }

    private func itemToolbar(_ item: ChatWorkItem) -> some View {
        HStack(spacing: 8) {
            viewModePicker(item)
            Spacer(minLength: 0)
            ChatWorkCopyButton(item: item, onCopy: copyWorkText).id(item.id)
            itemActions(item)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private func viewModePicker(_ item: ChatWorkItem) -> some View {
        HStack(spacing: 0) {
            viewModeButton("Preview", symbol: "eye", isSelected: !sourceIDs.contains(item.id)) {
                selectedText = ""
                sourceIDs.remove(item.id)
            }
            viewModeButton("Source", symbol: "chevron.left.forwardslash.chevron.right",
                           isSelected: sourceIDs.contains(item.id)) {
                selectedText = ""
                sourceIDs.insert(item.id)
            }
        }
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
    }

    private func viewModeButton(_ title: String, symbol: String, isSelected: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.primary : .secondary)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
                        .padding(2)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func itemActions(_ item: ChatWorkItem) -> some View {
        HStack(spacing: 4) {
            Button { translate(item) } label: {
                Image(systemName: "translate").frame(width: 30, height: 30)
            }
            .disabled(preparesTranslation)
            .help("Translate selected text or this page")
            .accessibilityLabel("Translate")
            .translationPresentation(isPresented: $showsTranslation, text: translationText)
            Button {
                addFeedback(for: item)
            } label: {
                Image(systemName: "text.bubble").frame(width: 30, height: 30)
            }
            .help("Add to chat")
            .accessibilityLabel("Add to chat")
            if item.canEdit {
                exportButton(item)
                Menu { fileLocationActions(item) } label: {
                    Image(nsImage: Self.pageMenuIcon).frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("File actions").accessibilityLabel("File actions")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .background(Color.primary.opacity(0.07), in: Capsule())
    }

    private func browserPageMenu(_ item: ChatWorkItem) -> some View {
        Menu {
            if item.canEdit {
                Picker("View", selection: Binding(
                    get: { sourceIDs.contains(item.id) },
                    set: { showsSource in
                        selectedText = ""
                        if showsSource { sourceIDs.insert(item.id) }
                        else { sourceIDs.remove(item.id) }
                    }
                )) {
                    Label("Preview", systemImage: "eye").tag(false)
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(true)
                }
                .pickerStyle(.inline)
                Divider()
                Button("Rename…", systemImage: "pencil") { beginRenaming(item) }
                Menu("Copy", systemImage: "doc.on.doc") {
                    Button("Source") { copyWorkText(item.content) }
                    Button("File name") { copyWorkText(item.title) }
                    if let url = chat.workFileURL(for: item) {
                        Button("File path") { copyWorkText(url.path) }
                    }
                }
                revealFileButton(item)
                Button("Download…", systemImage: "arrow.down.to.line") { export(item) }
                deleteFileButton(item)
                Divider()
            }
            Button("Translate", systemImage: "translate") { translate(item) }
                .disabled(preparesTranslation)
            Button("Add to chat", systemImage: "text.bubble") { addFeedback(for: item) }
            Divider()
            Button("Clear website data…", systemImage: "trash") { confirmsClearWebsiteData = true }
        } label: {
            Image(nsImage: Self.pageMenuIcon)
                .font(.system(size: 12))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Page actions")
        .accessibilityLabel("Page actions")
        .translationPresentation(isPresented: $showsTranslation, text: translationText)
    }

    private func copyWorkText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // Native macOS menus extract the label image and ignore SwiftUI rotation.
    private static let pageMenuIcon: NSImage = {
        let symbol = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        let side = max(symbol?.size.width ?? 12, symbol?.size.height ?? 12)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let symbol else { return false }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: 90)
            transform.concat()
            symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func exportButton(_ item: ChatWorkItem) -> some View {
        Button { export(item) } label: {
            Image(systemName: "arrow.down.to.line").frame(width: 30, height: 30)
        }
        .help("Export file")
        .accessibilityLabel("Export file")
    }

    private func translate(_ item: ChatWorkItem) {
        let sessionID = chat.currentSessionID
        preparesTranslation = true
        Task { @MainActor in
            defer { preparesTranslation = false }
            do {
                let text: String
                if !selectedText.isEmpty {
                    text = selectedText
                } else if item.resolvedKind == .website, let sessionID {
                    text = try await chat.workBrowser(for: item, sessionID: sessionID).textForTranslation()
                } else {
                    text = ChatWorkDocument.translationText(item.content)
                }
                guard chat.currentSessionID == sessionID, chat.workState.selectedID == item.id else { return }
                presentTranslation(text)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func itemContent(_ item: ChatWorkItem) -> some View {
        if sourceIDs.contains(item.id) && item.canEdit {
            ChatWorkSourceEditor(text: item.content, onChange: { text, previousContent in
                do { try chat.updateWorkItem(item.id, content: text, previousContent: previousContent) }
                catch { errorMessage = error.localizedDescription }
            }, onSelection: { selectedText = $0 },
               onAddToChat: { text in addFeedback(for: item, selectedText: text) },
               onRequestEdit: { text, request in try await requestEdit(for: item, text: text, request: request) })
            .id(item.id)
        } else if item.resolvedKind == .website, let sessionID = chat.currentSessionID {
            ChatWorkBrowserView(browser: chat.workBrowser(for: item, sessionID: sessionID))
                .id("\(sessionID):\(item.id)")
        } else {
            ScrollView {
                MarkdownRenderer(content: previewMarkdown(item), baseURL: item.sourceURL.flatMap(URL.init(string:)),
                                 fontSize: 15, imagePolicy: .document, onTranslate: presentTranslation,
                                 onAddToChat: { text in addFeedback(for: item, selectedText: text) },
                                 onRequestEdit: { text, request in
                                     try await requestEdit(for: item, text: text, request: request)
                                 })
                    .id(item.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
    }

    private func previewMarkdown(_ item: ChatWorkItem) -> String {
        guard item.resolvedKind == .code else { return ChatWorkDocument.renderedMarkdown(item.content) }
        let fence = String(repeating: "`", count: max(3, (item.content.components(separatedBy: .newlines)
            .map { $0.prefix(while: { $0 == "`" }).count }.max() ?? 0) + 1))
        return "\(fence)\(item.language ?? "")\n\(item.content)\n\(fence)"
    }

    private func addFeedback(for item: ChatWorkItem, annotation: ChatWorkPageAnnotation? = nil,
                             selectedText: String? = nil) {
        let target = ChatWorkFeedback(item: item, sessionID: chat.currentSessionID,
                                      annotation: annotation,
                                      selectedText: selectedText ?? (chat.workState.selectedID == item.id ? self.selectedText : ""))
        do { try chat.addWorkFeedback(target) }
        catch { errorMessage = error.localizedDescription }
    }

    private func requestEdit(for item: ChatWorkItem, text: String, request: String) async throws {
        let target = ChatWorkFeedback(item: item, sessionID: chat.currentSessionID,
                                      annotation: nil, selectedText: text)
        try await onRequestEdit(target, request)
    }

    private func create(title: String, kind: ChatWorkItem.Kind, content: String = "") {
        do {
            try chat.createWorkItem(title: title, kind: kind, content: content)
            if let id = chat.workState.selectedID { sourceIDs.insert(id) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func openWebsite(_ address: String) throws {
        let url = try ChatWorkState.addressURL(address)
        try chat.createWorkItem(title: url.host ?? "Website", kind: .website, url: url.absoluteString)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Import a copy of a UTF-8 document, code file, or HTML page (up to 256 KB)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ChatWorkState.maximumContentBytes else {
                throw ChatWorkError.invalid("Choose a text file up to 256 KB.")
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let ext = url.pathExtension.lowercased()
            let kind: ChatWorkItem.Kind = ["html", "htm"].contains(ext) ? .website
                : ["md", "markdown", "txt", ""].contains(ext) ? .document : .code
            try chat.createWorkItem(title: url.lastPathComponent, kind: kind, content: text, language: ext,
                                    sourceURL: kind == .document ? url.absoluteString : nil)
        } catch { errorMessage = error.localizedDescription }
    }

    private func export(_ item: ChatWorkItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.exportFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try item.content.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
    }

    private func presentTranslation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Select some text to translate."
            return
        }
        translationText = trimmed
        showsTranslation = true
    }
}

private struct ChatWorkCopyButton: View {
    let item: ChatWorkItem
    let onCopy: (String) -> Void
    @State private var copyID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            Button { copy(item.content) } label: {
                Text(copyID == nil ? "Copy" : "Copied")
                    .frame(width: 58, height: 30)
                    .contentShape(.rect)
            }
            .help(item.resolvedKind == .document ? "Copy Markdown" : "Copy source")
            .accessibilityLabel(copyID == nil ? "Copy content" : "Copied")
            Divider().frame(height: 16)
            Menu {
                Button(item.resolvedKind == .document ? "Copy Markdown" : "Copy source") { copy(item.content) }
                if item.resolvedKind == .document {
                    Button("Copy plain text") { copy(ChatWorkDocument.plainText(item.content)) }
                }
                Button("Copy file name") { copy(item.title) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 26, height: 30)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy options")
            .accessibilityLabel("Copy options")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .task(id: copyID) {
            guard copyID != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copyID = nil
        }
    }

    private func copy(_ text: String) {
        onCopy(text)
        copyID = UUID()
    }
}

private struct ChatWorkCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCard(configuration: configuration)
    }

    private struct HoverCard: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .onHover { isHovered = $0 }
        }
    }
}

private struct ChatWorkSourceEditor: NSViewRepresentable {
    let text: String
    let onChange: (String, String) -> Void
    let onSelection: (String) -> Void
    let onAddToChat: (String) -> Void
    let onRequestEdit: (String, String) async throws -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChatWorkSourceTextView.scrollableTextView()
        guard let editor = scroll.documentView as? ChatWorkSourceTextView else { return scroll }
        editor.selectionActions.onAddToChat = onAddToChat
        editor.selectionActions.onRequestEdit = onRequestEdit
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.string = text
        context.coordinator.lastContent = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Work source editor")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatWorkSourceTextView else { return }
        editor.selectionActions.onAddToChat = onAddToChat
        editor.selectionActions.onRequestEdit = onRequestEdit
        guard editor.string != text else { return }
        editor.selectionActions.dismiss()
        let selection = editor.selectedRange()
        editor.string = text
        context.coordinator.lastContent = text
        editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        editor.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatWorkSourceEditor
        var lastContent: String
        init(parent: ChatWorkSourceEditor) { self.parent = parent; lastContent = parent.text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            let previousContent = lastContent
            lastContent = editor.string
            parent.onChange(editor.string, previousContent)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            let range = editor.selectedRange()
            parent.onSelection((editor.string as NSString).substring(with: range))
        }

    }
}

/// The pane owns its chrome while open; window controls appear only when it is closed.
struct ChatWorkWindowControls: View {
    @ObservedObject var chat: ChatViewModel
    let isConfigurationVisible: Bool
    let toggleConfiguration: () -> Void

    var body: some View {
        if !chat.workState.isVisible {
            HStack(spacing: 0) {
                Button { chat.setWorkPaneVisible(true) } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .frame(width: ControlPanelLayout.topControlSize, height: ControlPanelLayout.topControlSize)
                        .contentShape(.rect)
                }
                .help("Show the work pane (⌘⇧B)")
                .accessibilityLabel("Work pane")
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button(action: toggleConfiguration) {
                    Image(systemName: "sidebar.right")
                        .frame(width: ControlPanelLayout.topControlSize, height: ControlPanelLayout.topControlSize)
                        .contentShape(.rect)
                }
                .help(isConfigurationVisible ? "Hide model configuration" : "Show model configuration")
                .accessibilityLabel(isConfigurationVisible ? "Hide model configuration" : "Show model configuration")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
    }
}
