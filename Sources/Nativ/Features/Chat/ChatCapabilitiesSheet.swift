import SwiftUI

private enum GlobalChatCapabilityKind: Int, CaseIterable {
    case connection
    case skill
    case tool

    var title: String {
        switch self {
        case .connection: "MCPs"
        case .skill: "Skills"
        case .tool: "Tools"
        }
    }
}

private enum GlobalChatCapabilityTarget: Hashable {
    case nativeTools([String])
    case customTool(String)
    case skill(UUID)
    case mcpServer(UUID)
}

private struct GlobalChatCapabilityItem: Identifiable {
    let id: String
    let target: GlobalChatCapabilityTarget
    let title: String
    let detail: String
    let kind: GlobalChatCapabilityKind
    let systemImage: String
    let isAvailable: Bool
    let setupSection: ExtensionsHubView.HubSection?
}

struct ChatCapabilitiesSheet: View {
    var model: NativModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openExtensionsHubSection) private var openExtensionsHubSection
    @State private var query = ""

    private var filteredItems: [GlobalChatCapabilityItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return allItems }
        return allItems.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.detail.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var allItems: [GlobalChatCapabilityItem] {
        var items = nativeToolItems
        items += model.settings.customTools.map { tool in
            GlobalChatCapabilityItem(
                id: "custom-tool-\(tool.id.uuidString)",
                target: .customTool(tool.toolName),
                title: tool.name,
                detail: "Custom tool",
                kind: .tool,
                systemImage: tool.kind == .script
                    ? "terminal"
                    : "point.3.connected.trianglepath.dotted",
                isAvailable: true,
                setupSection: nil
            )
        }
        items += model.settings.skills.map { skill in
            GlobalChatCapabilityItem(
                id: "skill-\(skill.id.uuidString)",
                target: .skill(skill.id),
                title: skill.name.isEmpty ? "Untitled skill" : skill.name,
                detail: "Skill",
                kind: .skill,
                systemImage: "sparkles",
                isAvailable: true,
                setupSection: nil
            )
        }
        items += model.settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { server in
                let entry = MCPServerCatalog.bundled.entry(matching: server)
                let requiredEnvironment = entry?.requiredEnvironment ?? []
                let hasRequiredEnvironment = requiredEnvironment.allSatisfy {
                    server.environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        == false
                }
                return GlobalChatCapabilityItem(
                    id: "mcp-\(server.id.uuidString)",
                    target: .mcpServer(server.id),
                    title: server.name.isEmpty ? "Untitled server" : server.name,
                    detail: "All tools from this MCP server",
                    kind: .connection,
                    systemImage: entry?.symbol ?? "server.rack",
                    isAvailable: hasRequiredEnvironment,
                    setupSection: hasRequiredEnvironment ? nil : .mcp
                )
            }

        return items.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private var nativeToolItems: [GlobalChatCapabilityItem] {
        var seenConfigurations = Set<ChatNativeToolConfiguration>()
        return ChatToolRegistry.descriptors(canEditImage: false).compactMap { descriptor in
            let toolName = descriptor.definition.function.name
            let configuration = descriptor.configuration
            if let configuration,
                configuration.toolNames.count > 1,
                !seenConfigurations.insert(configuration).inserted
            {
                return nil
            }
            let toolNames = descriptor.exposureToolNames
            return GlobalChatCapabilityItem(
                id: "native-tool-\(toolName)",
                target: .nativeTools(toolNames),
                title: configuration?.displayName ?? humanized(toolName),
                detail: "Built-in tool",
                kind: .tool,
                systemImage: configuration?.systemImage ?? "wrench.and.screwdriver",
                isAvailable: configuration?.isConfigured ?? true,
                setupSection: configuration?.isConfigured == false ? .tools : nil
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Capabilities")
                    .nativTextStyle(.sheetTitle)
                Spacer()
                NativHoverCloseButton { dismiss() }
            }

            Text("Choose what agents can use and what stays out of regular prompts.")
                .nativTextStyle(.supporting)
                .foregroundStyle(.secondary)

            ToolExposureModeExplanation()

            TextField("Search capabilities", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if filteredItems.isEmpty {
                        Text(
                            query.isEmpty
                                ? "No capabilities are available." : "No matching capabilities."
                        )
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        ForEach(GlobalChatCapabilityKind.allCases, id: \.rawValue) { kind in
                            capabilitySection(kind)
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(20)
        .frame(width: 620, height: 580)
    }

    @ViewBuilder
    private func capabilitySection(_ kind: GlobalChatCapabilityKind) -> some View {
        let sectionItems = filteredItems.filter { $0.kind == kind }
        if !sectionItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.title.uppercased())
                    .nativTextStyle(.badge)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(sectionItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        capabilityRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ item: GlobalChatCapabilityItem) -> some View {
        if item.isAvailable, item.kind == .skill {
            Button {
                toggle(item)
            } label: {
                capabilityRowContent(item)
            }
            .buttonStyle(.plain)
        } else {
            capabilityRowContent(item)
        }
    }

    private func capabilityRowContent(_ item: GlobalChatCapabilityItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(
                    item.isAvailable
                        ? Color.secondary
                        : Color(nsColor: .tertiaryLabelColor)
                )
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .nativTextStyle(.rowTitleEmphasized)
                    .foregroundStyle(item.isAvailable ? Color.primary : Color.secondary)

                if item.isAvailable {
                    Text(item.detail)
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                } else if let setupSection = item.setupSection {
                    GlobalCapabilitySetupDetail(detail: item.detail) {
                        openSetup(setupSection)
                    }
                }
            }

            Spacer(minLength: 20)

            if let mode = exposureModeBinding(for: item) {
                ToolExposureModeControl(mode: mode, title: item.title)
            } else if isEnabled(item) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Enabled globally")
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }

    private func isEnabled(_ item: GlobalChatCapabilityItem) -> Bool {
        guard item.isAvailable else { return false }
        switch item.target {
        case .nativeTools(let toolNames):
            return toolNames.allSatisfy(model.settings.isToolEnabled)
        case .customTool(let toolName):
            return model.settings.isToolEnabled(toolName)
        case .skill(let id):
            return model.settings.skills.first { $0.id == id }?.isEnabled == true
        case .mcpServer(let id):
            return model.settings.mcpServers.first { $0.id == id }?.isEnabled == true
        }
    }

    private func exposureModeBinding(
        for item: GlobalChatCapabilityItem
    ) -> Binding<ToolExposureMode>? {
        guard item.isAvailable else { return nil }
        switch item.target {
        case .nativeTools(let toolNames):
            return Binding(
                get: {
                    let modes = Set(toolNames.map {
                        model.settings.toolExposureMode(for: $0)
                    })
                    return modes.count == 1 ? modes.first ?? .automatic : .automatic
                },
                set: { mode in
                    model.settings.setToolExposureMode(mode, toolNames: toolNames)
                }
            )
        case .customTool(let toolName):
            return Binding(
                get: {
                    model.settings.toolExposureMode(
                        for: toolName,
                        default: .automatic
                    )
                },
                set: { mode in
                    model.settings.setToolExposureMode(mode, toolName: toolName)
                }
            )
        case .mcpServer(let id):
            guard model.settings.mcpServers.contains(where: { $0.id == id }) else {
                return nil
            }
            return Binding(
                get: {
                    guard let server = model.settings.mcpServers.first(where: { $0.id == id })
                    else { return .off }
                    return model.settings.mcpServerExposureMode(for: server)
                },
                set: { mode in
                    model.settings.setMCPServerExposureMode(mode, serverID: id)
                }
            )
        case .skill:
            return nil
        }
    }

    private func toggle(_ item: GlobalChatCapabilityItem) {
        switch item.target {
        case .skill(let id):
            guard let index = model.settings.skills.firstIndex(where: { $0.id == id }) else {
                return
            }
            model.settings.skills[index].isEnabled.toggle()
        case .nativeTools, .customTool, .mcpServer:
            break
        }
    }

    private func humanized(_ name: String) -> String {
        name.split(separator: "_")
            .map { String($0).capitalized }
            .joined(separator: " ")
    }

    private func openSetup(_ section: ExtensionsHubView.HubSection) {
        let openExtensionsHubSection = openExtensionsHubSection
        dismiss()
        Task { @MainActor in
            await Task.yield()
            openExtensionsHubSection(section)
        }
    }
}

struct ChatKitsPickerSheet: View {
    var model: NativModel
    @ObservedObject var manager: NativExtensionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let kits = model.kitLibrary.catalog.kits
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Kits")
                    .nativTextStyle(.sheetTitle)
                Spacer()
                NativHoverCloseButton { dismiss() }
            }

            Text("Make a ready-made set of capabilities discoverable in every chat.")
                .nativTextStyle(.supporting)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(kits) { kit in
                        VStack(spacing: 0) {
                            kitRow(kit)
                            if kit.id != kits.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(20)
        .presentationSizing(.form)
    }

    @ViewBuilder
    private func kitRow(_ kit: NativKit) -> some View {
        let state = NativKitActivation.state(
            of: kit,
            model: model,
            isExtensionEnabled: manager.isEnabled(extensionID:)
        )
        if state == .enabled {
            kitRowContent(kit, state: state)
                .accessibilityElement(children: .combine)
        } else {
            Button {
                NativKitActivation.enableMissing(
                    in: kit,
                    model: model,
                    isExtensionEnabled: manager.isEnabled(extensionID:),
                    enableExtension: { manager.setEnabled(true, extensionID: $0) }
                )
            } label: {
                kitRowContent(kit, state: state)
            }
            .buttonStyle(.plain)
            .accessibilityHint(state == .partial ? "Enables the missing Kit capabilities" : "Enables this Kit")
        }
    }

    private func kitRowContent(_ kit: NativKit, state: NativKitState) -> some View {
        let actionTitle = switch state {
        case .off: "Enable"
        case .partial: "Enable Missing"
        case .enabled: "Enabled"
        }
        return HStack(spacing: 12) {
            Image(systemName: kit.symbol)
                .font(.headline)
                .foregroundStyle(Color.nativTint(kit.tintName))
                .frame(minWidth: 28, minHeight: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(kit.name)
                    .nativTextStyle(.rowTitle)
                    .foregroundStyle(.primary)
                Text(kit.summary)
                    .nativTextStyle(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    actionTitle,
                    systemImage: state == .enabled ? "checkmark.circle.fill" : "plus.circle"
                )
                .nativTextStyle(.actionLabel)
                .foregroundStyle(state == .enabled ? Color.green : Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }
}

private struct GlobalCapabilitySetupDetail: View {
    let detail: String
    let action: () -> Void

    var body: some View {
        Link(destination: URL(string: "https://nativ.local/extensions/setup")!) {
            HStack(spacing: 0) {
                Text(detail + " · ")
                    .foregroundColor(.secondary)
                Text("Needs setup")
                    .foregroundColor(.accentColor)
                    .underline()
            }
        }
        .nativTextStyle(.metadata)
        .multilineTextAlignment(.leading)
        .buttonStyle(.plain)
        .environment(
            \.openURL,
            OpenURLAction { _ in
                action()
                return .handled
            })
    }
}
