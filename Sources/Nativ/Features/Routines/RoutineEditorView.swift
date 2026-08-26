import AppKit
import NativServerKit
import SwiftUI

struct RoutineEditor: View {
    let draft: RoutineDraft
    let availableModelIDs: [String]
    let toolCapableModelIDs: Set<String>
    var model: NativModel
    @ObservedObject var mcpHost: MCPHostManager
    @ObservedObject private var notifications = NativNotificationService.shared
    let isExistingTask: Bool
    let onSave: (Routine) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var modelID: String
    @State private var weekdays: Set<Int>
    @State private var time: Date
    @State private var capabilities: Set<ScheduledCapability>
    @State private var notifyOnFinish: Bool
    @State private var isSelectingCapabilities = false

    init(
        draft: RoutineDraft,
        availableModelIDs: [String],
        toolCapableModelIDs: Set<String>,
        model: NativModel,
        mcpHost: MCPHostManager,
        isExistingTask: Bool,
        onSave: @escaping (Routine) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.availableModelIDs = availableModelIDs
        self.toolCapableModelIDs = toolCapableModelIDs
        self.model = model
        self.mcpHost = mcpHost
        self.isExistingTask = isExistingTask
        self.onSave = onSave
        self.onCancel = onCancel

        let routine = draft.routine
        _name = State(initialValue: routine.name)
        _instructions = State(initialValue: routine.instructions)
        _modelID = State(initialValue: routine.modelID)
        _weekdays = State(initialValue: routine.schedule.weekdays)
        var components = DateComponents()
        components.hour = routine.schedule.hour
        components.minute = routine.schedule.minute
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _capabilities = State(initialValue: Set(routine.capabilities))
        _notifyOnFinish = State(initialValue: routine.notifyOnFinish)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.isEmpty
            && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresToolCalling || toolCapableModelIDs.contains(modelID))
    }

    private var requiresToolCalling: Bool {
        capabilities.contains { capability in
            switch capability {
            case .skill:
                return false
            case .kit(let id):
                return NativKitCatalog.bundled.kit(id: id)?.mcpServerIDs.isEmpty == false
            case .mcpServer, .tool:
                return true
            }
        }
    }

    private var capabilityOptions: [ScheduledCapabilityOption] {
        var options = NativKitCatalog.bundled.kits.map { kit in
            ScheduledCapabilityOption(
                capability: .kit(kit.id),
                section: .kits,
                title: kit.name,
                detail: kit.inventory.isEmpty
                    ? kit.summary
                    : "\(kit.summary) Selecting it enables \(kit.inventory) in Extensions.",
                systemImage: kit.symbol
            )
        }

        let enabledServers = model.settings.mcpServers.filter(\.isEnabled)
        options += enabledServers.map { server in
            ScheduledCapabilityOption(
                capability: .mcpServer(server.id),
                section: .mcpServers,
                title: server.name.isEmpty ? "MCP server" : server.name,
                detail: "All tools provided by this server",
                systemImage: "server.rack"
            )
        }

        let disabledNames = Set(model.settings.disabledToolNames)
        options += ChatToolRegistry.descriptors(canEditImage: false)
            .filter {
                $0.definition.function.name != ChatSwitchModelToolRegistry.toolName
                    && !disabledNames.contains($0.definition.function.name)
                    && ($0.configuration != .webSearch || ChatWebSearchToolRegistry.isConfigured())
                    && ($0.configuration != .fileRead
                        || FileReadAccessPolicy.isConfigured(
                            rootPath: model.settings.fileReadRootPath
                        ))
            }
            .map { descriptor in
                let definition = descriptor.definition.function
                return ScheduledCapabilityOption(
                    capability: .tool(ScheduledTool(provider: .builtIn, name: definition.name)),
                    section: .tools,
                    title: descriptor.configuration?.displayName ?? humanized(definition.name),
                    detail: definition.name == ChatReadFileToolRegistry.toolName
                        ? "Reads only within \(model.settings.fileReadRootPath ?? "the configured File Read folder"). Runs without confirmation in scheduled tasks."
                        : definition.description,
                    systemImage: "hammer"
                )
            }

        options += model.settings.customTools
            .filter { !disabledNames.contains($0.toolName) }
            .map { tool in
                ScheduledCapabilityOption(
                    capability: .tool(ScheduledTool(provider: .custom(tool.id), name: tool.toolName)),
                    section: .tools,
                    title: tool.name,
                    detail: tool.kind == .script
                        ? "\(tool.displaySummary). Runs without confirmation in scheduled tasks."
                        : tool.displaySummary,
                    systemImage: "wrench.and.screwdriver"
                )
            }

        for server in enabledServers {
            let definitions = mcpHost.toolDefinitions(forServer: server.id)
            for tool in mcpHost.tools(forServer: server.id) where !disabledNames.contains(tool.name) {
                let detail = definitions.first(where: { $0.function.name == tool.name })?
                    .function.description ?? "Provided by \(server.name)"
                options.append(ScheduledCapabilityOption(
                    capability: .tool(ScheduledTool(provider: .mcp(server.id), name: tool.displayName)),
                    section: .tools,
                    title: tool.displayName,
                    detail: detail,
                    systemImage: "hammer",
                    source: server.name
                ))
            }
        }

        options += model.settings.skills
            .filter(\.isEnabled)
            .map { skill in
                ScheduledCapabilityOption(
                    capability: .skill(skill.id),
                    section: .skills,
                    title: skill.name,
                    detail: skill.instructions,
                    systemImage: "sparkles"
                )
            }

        return options.sorted {
            if $0.section != $1.section { return $0.section.sortOrder < $1.section.sortOrder }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var selectedCapabilityOptions: [ScheduledCapabilityOption] {
        capabilities.map { capability in
            capabilityOptions.first(where: { $0.capability == capability })
                ?? ScheduledCapabilityOption.unavailable(capability)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder
    private var capabilitySelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedCapabilityOptions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No tools selected")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selectedCapabilityOptions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: option.systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(option.summaryLine)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(option.section.singularTitle)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                            Button {
                                capabilities.remove(option.capability)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(option.title)")
                            .accessibilityLabel("Remove \(option.title)")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }

            HStack {
                Button {
                    isSelectingCapabilities = true
                } label: {
                    Label(
                        capabilities.isEmpty ? "Add tools" : "Manage tools",
                        systemImage: "plus"
                    )
                }
                .controlSize(.small)
                Spacer()
                if !capabilities.isEmpty {
                    Text("\(capabilities.count) selected")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func humanized(_ name: String) -> String {
        name.split(separator: "_")
            .map { String($0).capitalized }
            .joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("Name") {
                        TextField("Scheduled task name", text: $name)
                            .textFieldStyle(.plain)
                    }
                    field("Instructions") {
                        TextEditor(text: $instructions)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 130)
                            .font(.body)
                    }
                    field("Model") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Model", selection: $modelID) {
                                Text("Select a model").tag("")
                                ForEach(availableModelIDs, id: \.self) { id in
                                    Text(NativFormatting.truncateModelName(id, maxLength: 52)).tag(id)
                                }
                            }
                            .labelsHidden()
                            if requiresToolCalling, !toolCapableModelIDs.contains(modelID) {
                                Label(
                                    "Choose a model that supports tool calling to use these tools.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                    if draft.routine.runsOnSchedule {
                        field("Schedule") { scheduleContent }
                    }
                    field("Tools") {
                        capabilitySelection
                    }
                    notificationPreference
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isExistingTask ? "Save" : "Create") {
                    onSave(makeRoutine())
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nativMainContentBackground)
        .overlay(alignment: .topTrailing) {
            NativHoverCloseButton(action: onCancel, help: "Close editor")
                .padding(16)
        }
        .sheet(isPresented: $isSelectingCapabilities) {
            ScheduledCapabilityPicker(
                options: capabilityOptions,
                selection: $capabilities
            )
        }
        .onAppear {
            notifications.refreshAuthorizationStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            notifications.refreshAuthorizationStatus()
        }
        .onExitCommand(perform: onCancel)
    }

    private var notificationPreference: some View {
        box {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Notify me when this scheduled task finishes",
                    isOn: $notifyOnFinish
                )
                .disabled(!notifications.isAuthorized)

                if notifications.authorizationStatus != .authorized {
                    Divider()

                    HStack(spacing: 12) {
                        Label(notificationPermissionMessage, systemImage: "bell.badge")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Spacer()
                        notificationPermissionControl
                    }
                }
            }
        }
    }

    private var notificationPermissionMessage: String {
        switch notifications.authorizationStatus {
        case .unknown:
            "Checking notification access…"
        case .notDetermined:
            "Allow notifications to receive completion alerts."
        case .denied:
            "Notifications are blocked in System Settings."
        case .authorized:
            ""
        }
    }

    @ViewBuilder
    private var notificationPermissionControl: some View {
        switch notifications.authorizationStatus {
        case .unknown:
            ProgressView()
                .controlSize(.small)
        case .notDetermined:
            Button(notifications.isRequestingAuthorization ? "Requesting…" : "Allow") {
                notifications.requestAuthorization()
            }
            .controlSize(.small)
            .disabled(notifications.isRequestingAuthorization)
        case .denied:
            Button("Open Settings…") {
                notifications.openSystemSettings()
            }
            .controlSize(.small)
        case .authorized:
            EmptyView()
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Time")
                Spacer()
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            weekdayPicker
        }
    }

    @ViewBuilder
    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            box { content() }
        }
    }

    @ViewBuilder
    private func box<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { weekday in
                let symbol = Calendar.current.veryShortWeekdaySymbols[weekday - 1]
                let isOn = weekdays.contains(weekday)
                Button(symbol) {
                    if isOn { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? Color.accentColor : Color.secondary)
                .accessibilityLabel(Calendar.current.weekdaySymbols[weekday - 1])
                .accessibilityValue(isOn ? "Selected" : "Not selected")
            }
            Spacer()
            Text(weekdays.isEmpty ? "Every day" : "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func makeRoutine() -> Routine {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let schedule = RoutineSchedule(
            weekdays: weekdays,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0
        )
        var routine = draft.routine
        routine.name = name.trimmingCharacters(in: .whitespaces)
        routine.instructions = instructions
        routine.modelID = modelID
        routine.schedule = schedule
        routine.capabilities = capabilities.sorted { $0.id < $1.id }
        routine.notifyOnFinish = notifyOnFinish
        return routine
    }
}

private enum ScheduledCapabilitySection: String, CaseIterable, Identifiable {
    case all = "All"
    case kits = "Kits"
    case mcpServers = "MCP servers"
    case tools = "Tools"
    case skills = "Skills"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .kits: "shippingbox"
        case .mcpServers: "server.rack"
        case .tools: "hammer"
        case .skills: "sparkles"
        }
    }

    var singularTitle: String {
        switch self {
        case .all: "Tool"
        case .kits: "Kit"
        case .mcpServers: "MCP"
        case .tools: "Tool"
        case .skills: "Skill"
        }
    }

    var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

private struct ScheduledCapabilityOption: Identifiable {
    let capability: ScheduledCapability
    let section: ScheduledCapabilitySection
    let title: String
    let detail: String
    let systemImage: String
    var source: String? = nil

    var id: String { capability.id }

    var summaryLine: String {
        guard let source, !source.isEmpty else { return detail }
        return "\(source) · \(detail)"
    }

    static func unavailable(_ capability: ScheduledCapability) -> Self {
        let section: ScheduledCapabilitySection
        let title: String
        let systemImage: String
        switch capability {
        case .kit(let id):
            section = .kits
            title = id
            systemImage = "shippingbox"
        case .mcpServer:
            section = .mcpServers
            title = "Unavailable MCP server"
            systemImage = "server.rack"
        case .tool(let tool):
            section = .tools
            title = tool.name
            systemImage = "hammer"
        case .skill:
            section = .skills
            title = "Unavailable skill"
            systemImage = "sparkles"
        }
        return Self(
            capability: capability,
            section: section,
            title: title,
            detail: "This tool is no longer available.",
            systemImage: systemImage
        )
    }
}

private struct ScheduledCapabilityPicker: View {
    let options: [ScheduledCapabilityOption]
    @Binding var selection: Set<ScheduledCapability>

    @Environment(\.dismiss) private var dismiss
    @State private var section: ScheduledCapabilitySection = .all
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                capabilityList
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 590)
        .onExitCommand(perform: dismiss.callAsFunction)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tools")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose the tools this scheduled task can use.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(ScheduledCapabilitySection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.systemImage)
                            .frame(width: 18)
                        Text(item.rawValue)
                        Spacer(minLength: 4)
                        let count = count(for: item)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(section == item ? Color.accentColor : Color.primary)
                    .background(
                        section == item ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 172)
    }

    private var capabilityList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tools", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(14)

            Divider()

            if filteredOptions.isEmpty {
                ContentUnavailableView(
                    "No tools",
                    systemImage: "magnifyingglass",
                    description: Text(emptyMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredOptions.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { Divider().padding(.leading, 52) }
                            capabilityRow(option)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func capabilityRow(_ option: ScheduledCapabilityOption) -> some View {
        let isSelected = selection.contains(option.capability)
        return Button {
            if isSelected {
                selection.remove(option.capability)
            } else {
                selection.insert(option.capability)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        (isSelected ? Color.accentColor : Color.secondary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(option.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(option.section.singularTitle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                    Text(option.summaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(selection.isEmpty ? "No tools selected" : "\(selection.count) selected")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: dismiss.callAsFunction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var filteredOptions: [ScheduledCapabilityOption] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { option in
            let matchesSection = section == .all || option.section == section
            let matchesQuery = normalizedQuery.isEmpty
                || option.title.localizedCaseInsensitiveContains(normalizedQuery)
                || option.detail.localizedCaseInsensitiveContains(normalizedQuery)
                || option.source?.localizedCaseInsensitiveContains(normalizedQuery) == true
            return matchesSection && matchesQuery
        }
    }

    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try another name or description."
        }
        switch section {
        case .mcpServers:
            return "Enable an MCP server in Extensions to use it here."
        case .tools:
            return "Enable a built-in, custom, or MCP tool in Extensions to use it here."
        case .skills:
            return "Enable a skill in Extensions to use it here."
        default:
            return "Nothing is available in this category."
        }
    }

    private func count(for section: ScheduledCapabilitySection) -> Int {
        guard section != .all else { return selection.count }
        let available = Set(options.filter { $0.section == section }.map(\.capability))
        return selection.intersection(available).count
    }
}
