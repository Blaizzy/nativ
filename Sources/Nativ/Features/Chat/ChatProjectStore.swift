import Foundation

struct ChatProject: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date
    var updatedAt: Date
    var isCollapsed: Bool
    var sortOrder: Int?

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isCollapsed: Bool = false,
        sortOrder: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isCollapsed = isCollapsed
        self.sortOrder = sortOrder
    }

    static func sidebarSort(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case (let left?, let right?):
            return left == right
                ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                : left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

enum ChatProjectStoreError: LocalizedError, Equatable {
    case invalidDirectory
    case directoryNotWritable
    case duplicateDirectory(String)
    case projectNotFound
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            "Choose an existing folder that Nativ can read."
        case .directoryNotWritable:
            "Choose a folder that Nativ can read and write."
        case .duplicateDirectory(let name):
            "That folder is already used by the project “\(name)”."
        case .projectNotFound:
            "The project no longer exists."
        case .persistenceFailed(let detail):
            "The project could not be saved: \(detail)"
        }
    }
}

enum ChatProjectSessionRemovalDisposition {
    case keepChats
    case deleteChats
}

struct ChatToolScope: Equatable, Sendable {
    static let projectToolNames = Set(
        ChatReadFileToolRegistry.toolNames
            + ChatFileWriteToolRegistry.toolNames
            + [ChatTerminalToolRegistry.toolName]
    )

    let projectID: UUID?
    let projectName: String?
    let rootPath: String?
    let projectToolsEnabled: Bool

    var isProject: Bool {
        projectID != nil
    }

    var projectToolsAreAvailable: Bool {
        isProject && projectToolsEnabled && rootPath != nil
    }

    var fileReadRootPath: String? {
        rootPath
    }

    var fileWriteRootPath: String? {
        rootPath
    }

    var terminalWorkingDirectory: String? {
        isProject ? rootPath : nil
    }

    var systemPrompt: String? {
        guard isProject else { return nil }
        guard let rootPath else {
            return """
                This chat belongs to a Nativ project, but its folder is currently unavailable. \
                Do not claim to have read, searched, changed, or run commands in the project. \
                Ask the user to locate the project folder in the sidebar if filesystem access is needed.
                """
        }
        let name = projectName ?? "Project"
        if projectToolsEnabled {
            return """
                You are working in the Nativ project “\(name)”. Its workspace root is \
                \(rootPath). Resolve relative file-tool paths from that root. Terminal commands start \
                in that directory but are not otherwise filesystem-confined. Every terminal command \
                still requires the user's approval.
                """
        }
        return """
            This chat belongs to the Nativ project “\(name)” at \(rootPath), but project agentic \
            tools are disabled in Settings. Do not claim to have accessed the project filesystem.
            """
    }

    static func standalone(settings: NativSettings) -> Self {
        Self(
            projectID: nil,
            projectName: nil,
            rootPath: nil,
            projectToolsEnabled: false
        )
    }
}

@MainActor
final class ChatProjectStore: ObservableObject {
    @Published private(set) var projects: [ChatProject]
    @Published private(set) var unavailableProjectIDs: Set<UUID> = []

    private let fileManager: FileManager
    private let storageURL: URL

    init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        projects = Self.loadProjects(from: self.storageURL)
        refreshRootAvailability()
    }

    func project(withID id: UUID) -> ChatProject? {
        projects.first { $0.id == id }
    }

    func createProject(directoryURL: URL, name: String? = nil) throws -> ChatProject {
        let rootURL = try validatedRootURL(directoryURL)
        if let duplicate = projects.first(where: { $0.rootPath == rootURL.path }) {
            throw ChatProjectStoreError.duplicateDirectory(duplicate.name)
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = ChatProject(
            name: trimmedName.isEmpty ? rootURL.lastPathComponent : trimmedName,
            rootPath: rootURL.path,
            sortOrder: nextSortOrder
        )
        projects.append(project)
        projects.sort(by: ChatProject.sidebarSort)
        do {
            try persist()
        } catch {
            projects.removeAll { $0.id == project.id }
            throw error
        }
        refreshRootAvailability()
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let index = projects.firstIndex(where: { $0.id == id })
        else {
            return
        }
        projects[index].name = trimmed
        projects[index].updatedAt = Date()
        projects.sort(by: ChatProject.sidebarSort)
        try? persist()
    }

    func setCollapsed(_ id: UUID, collapsed: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        projects[index].isCollapsed = collapsed
        projects[index].updatedAt = Date()
        try? persist()
    }

    func setAllCollapsed(_ collapsed: Bool) {
        guard projects.contains(where: { $0.isCollapsed != collapsed }) else {
            return
        }
        for index in projects.indices {
            projects[index].isCollapsed = collapsed
            projects[index].updatedAt = Date()
        }
        try? persist()
    }

    func replaceRoot(for id: UUID, with directoryURL: URL) throws {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            throw ChatProjectStoreError.projectNotFound
        }
        let rootURL = try validatedRootURL(directoryURL)
        if let duplicate = projects.first(where: {
            $0.id != id && $0.rootPath == rootURL.path
        }) {
            throw ChatProjectStoreError.duplicateDirectory(duplicate.name)
        }
        let previousProject = projects[index]
        projects[index].rootPath = rootURL.path
        projects[index].updatedAt = Date()
        do {
            try persist()
        } catch {
            projects[index] = previousProject
            throw error
        }
        refreshRootAvailability()
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        unavailableProjectIDs.remove(id)
        try? persist()
    }

    func refreshRootAvailability() {
        unavailableProjectIDs = Set(
            projects.compactMap { project in
                validatedRootPath(project.rootPath) == nil ? project.id : nil
            }
        )
    }

    func isRootAvailable(for project: ChatProject) -> Bool {
        !unavailableProjectIDs.contains(project.id)
            && validatedRootPath(project.rootPath) != nil
    }

    func toolScope(
        for projectID: UUID?,
        settings: NativSettings
    ) -> ChatToolScope {
        guard let projectID else {
            return .standalone(settings: settings)
        }
        guard let project = project(withID: projectID) else {
            return ChatToolScope(
                projectID: projectID,
                projectName: nil,
                rootPath: nil,
                projectToolsEnabled: settings.projectToolsEnabled
            )
        }
        return ChatToolScope(
            projectID: project.id,
            projectName: project.name,
            rootPath: validatedRootPath(project.rootPath),
            projectToolsEnabled: settings.projectToolsEnabled
        )
    }

    private var nextSortOrder: Int {
        (projects.compactMap(\.sortOrder).max() ?? -1) + 1
    }

    private func validatedRootURL(_ directoryURL: URL) throws -> URL {
        let path = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard FileReadAccessPolicy.isConfigured(rootPath: path) else {
            throw ChatProjectStoreError.invalidDirectory
        }
        guard let root = FileWriteAccessPolicy.configuredRootURL(rootPath: path) else {
            throw ChatProjectStoreError.directoryNotWritable
        }
        do {
            _ = try FileReadAccessPolicy(rootPath: root.path).resolve(path: ".")
            _ = try FileWriteAccessPolicy(rootPath: root.path).resolve(path: ".")
        } catch {
            throw ChatProjectStoreError.invalidDirectory
        }
        return root
    }

    private func validatedRootPath(_ path: String) -> String? {
        guard
            let url = try? validatedRootURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
        else {
            return nil
        }
        return url.path
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            throw ChatProjectStoreError.persistenceFailed(error.localizedDescription)
        }
    }

    private static func loadProjects(from url: URL) -> [ChatProject] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([ChatProject].self, from: data)) ?? [])
            .sorted(by: ChatProject.sidebarSort)
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        let applicationSupport =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
        return
            applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("projects.json")
    }
}
