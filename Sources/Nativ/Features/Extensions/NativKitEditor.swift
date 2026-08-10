import NativServerKit
import SwiftUI

struct NativKitEditor: View {
    private enum Category: String, CaseIterable, Identifiable {
        case mcp = "MCPs"
        case tools = "Tools"
        case skills = "Skills"

        var id: Self { self }
    }

    @ObservedObject var host: MCPHostManager
    @ObservedObject var model: NativModel
    let onSave: (CustomNativKit) -> Void
    let onCancel: () -> Void
    let onOpenCapability: (NativKitCapabilityReference) -> Void
    let onReset: (() -> Void)?

    @State private var draft: CustomNativKit
    @State private var category: Category = .mcp
    @State private var query = ""

    init(
        kit: CustomNativKit,
        host: MCPHostManager,
        model: NativModel,
        onSave: @escaping (CustomNativKit) -> Void,
        onCancel: @escaping () -> Void,
        onOpenCapability: @escaping (NativKitCapabilityReference) -> Void,
        onReset: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: kit)
        self.host = host
        self.model = model
        self.onSave = onSave
        self.onCancel = onCancel
        self.onOpenCapability = onOpenCapability
        self.onReset = onReset
    }

    private var inventory: NativKitCapabilityInventory {
        NativKitCapabilityInventory(settings: model.settings, host: host)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.contents.normalized().isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            capabilityList
            Divider()
            footer
        }
        .frame(width: 570, height: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            NativTintedIconTile(symbol: draft.symbol, tint: draft.tint, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                if draft.isBuiltIn {
                    Text(draft.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text(draft.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    TextField("Kit name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                    TextField("Description", text: $draft.summary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            NativHoverCloseButton { onCancel() }
        }
        .padding(18)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Capability type", selection: $category) {
                ForEach(Category.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search \(category.rawValue.lowercased())", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var capabilityList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch category {
                case .mcp:
                    mcpRows
                case .tools:
                    toolRows
                case .skills:
                    skillRows
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mcpRows: some View {
        let choices = inventory.mcpChoices.filter { matches($0.name, detail: $0.detail) }
        if choices.isEmpty {
            emptyState("No configured MCPs match this search.", symbol: "server.rack")
        } else {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { Divider() }
                mcpRow(choice)
            }
        }
        unavailableMCPSelections(known: Set(inventory.mcpChoices.flatMap(\.allReferences)))
    }

    private func mcpRow(_ choice: NativKitMCPChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapabilitySelectionRow(
                title: choice.name,
                detail: choice.detail,
                readiness: choice.readiness,
                isOn: mcpIncludedBinding(choice),
                onOpenCapability: { onOpenCapability(.mcp(choice.reference)) }
            )
            if choice.tools.isEmpty {
                Text(mcpHint(choice))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 30)
                    .padding(.bottom, 2)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("All tools", isOn: mcpAllBinding(choice))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .medium))
                    ForEach(choice.tools) { tool in
                        Toggle(tool.name, isOn: mcpToolBinding(
                            choice: choice,
                            availableTools: choice.tools,
                            toolName: tool.name
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(.leading, 30)
                .padding(.bottom, 5)
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var toolRows: some View {
        let choices = inventory.toolChoices.filter { matches($0.name, detail: $0.detail) }
        if choices.isEmpty {
            emptyState("No tools match this search.", symbol: "hammer")
        } else {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { Divider() }
                CapabilitySelectionRow(
                    title: choice.name,
                    detail: choice.detail,
                    readiness: choice.readiness,
                    isOn: toolBinding(choice),
                    onOpenCapability: openCapabilityAction(for: choice)
                )
                .padding(.vertical, 9)
            }
        }
        unavailableToolSelections(choices: inventory.toolChoices)
    }

    @ViewBuilder
    private var skillRows: some View {
        let choices = inventory.skillChoices.filter { matches($0.name, detail: $0.detail) }
        if choices.isEmpty {
            emptyState("No skills match this search.", symbol: "sparkles")
        } else {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { Divider() }
                CapabilitySelectionRow(
                    title: choice.name,
                    detail: choice.detail,
                    readiness: choice.readiness,
                    isOn: skillBinding(choice),
                    onOpenCapability: { onOpenCapability(.skill(choice.reference)) }
                )
                .padding(.vertical, 9)
            }
        }
        unavailableSkillSelections(known: Set(inventory.skillChoices.flatMap(\.allReferences)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(selectionSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let onReset {
                Button("Reset", action: onReset)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Save changes") { onSave(draft.normalized()) }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .padding(16)
    }

    private var selectionSummary: String {
        let contents = draft.contents.normalized()
        let count = contents.mcpSelections.count
            + contents.nativeToolNames.count
            + contents.customToolIDs.count
            + contents.skillReferences.count
        return "\(count) selected"
    }

    private func mcpHint(_ choice: NativKitMCPChoice) -> String {
        if isMCPAllSelected(choice) {
            return "All tools from this MCP are selected."
        }
        return choice.readiness == .ready
            ? "This MCP did not advertise any tools."
            : "Turn on and connect this MCP to choose individual tools."
    }

    private func mcpAllBinding(_ choice: NativKitMCPChoice) -> Binding<Bool> {
        let references = Set(choice.allReferences)
        return Binding(
            get: { isMCPAllSelected(choice) },
            set: { selected in
                draft.contents.mcpSelections.removeAll { references.contains($0.server) }
                if selected {
                    draft.contents.mcpSelections.append(
                        NativKitMCPSelection(server: choice.reference, tools: .all)
                    )
                }
            }
        )
    }

    private func mcpIncludedBinding(_ choice: NativKitMCPChoice) -> Binding<Bool> {
        let references = Set(choice.allReferences)
        return Binding(
            get: { draft.contents.mcpSelections.contains { references.contains($0.server) } },
            set: { selected in
                if selected {
                    if !draft.contents.mcpSelections.contains(where: { references.contains($0.server) }) {
                        draft.contents.mcpSelections.append(
                            NativKitMCPSelection(server: choice.reference, tools: .all)
                        )
                    }
                } else {
                    draft.contents.mcpSelections.removeAll { references.contains($0.server) }
                }
            }
        )
    }

    private func mcpToolBinding(
        choice: NativKitMCPChoice,
        availableTools: [MCPHostedTool],
        toolName: String
    ) -> Binding<Bool> {
        let references = Set(choice.allReferences)
        return Binding(
            get: {
                guard let selection = draft.contents.mcpSelections.first(where: {
                    references.contains($0.server)
                }) else {
                    return false
                }
                switch selection.tools {
                case .all: return true
                case .named(let names): return names.contains(toolName)
                }
            },
            set: { selected in
                let index = draft.contents.mcpSelections.firstIndex {
                    references.contains($0.server)
                }
                let currentNames: [String]
                if let index {
                    switch draft.contents.mcpSelections[index].tools {
                    case .all:
                        currentNames = availableTools.map(\.name)
                    case .named(let names):
                        currentNames = names
                    }
                } else {
                    currentNames = []
                }
                var names = Set(currentNames)
                if selected { names.insert(toolName) } else { names.remove(toolName) }
                draft.contents.mcpSelections.removeAll { references.contains($0.server) }
                if !names.isEmpty {
                    draft.contents.mcpSelections.append(
                        NativKitMCPSelection(
                            server: choice.reference,
                            tools: .named(Array(names).sorted())
                        )
                    )
                }
            }
        )
    }

    private func isMCPAllSelected(_ choice: NativKitMCPChoice) -> Bool {
        let references = Set(choice.allReferences)
        guard let selection = draft.contents.mcpSelections.first(where: {
            references.contains($0.server)
        }) else {
            return false
        }
        if case .all = selection.tools { return true }
        return false
    }

    private func toolBinding(_ choice: NativKitToolChoice) -> Binding<Bool> {
        switch choice.source {
        case .native:
            let name = choice.id.replacingOccurrences(of: "native:", with: "")
            return containsBinding(name, in: \NativKitContents.nativeToolNames)
        case .custom:
            guard let id = choice.customToolID else { return .constant(false) }
            return containsBinding(id, in: \NativKitContents.customToolIDs)
        }
    }

    private func capabilityReference(
        for choice: NativKitToolChoice
    ) -> NativKitCapabilityReference? {
        switch choice.source {
        case .native:
            .nativeTool(String(choice.id.dropFirst("native:".count)))
        case .custom:
            choice.customToolID.map(NativKitCapabilityReference.customTool)
        }
    }

    private func openCapabilityAction(for choice: NativKitToolChoice) -> (() -> Void)? {
        guard let capability = capabilityReference(for: choice) else { return nil }
        return { onOpenCapability(capability) }
    }

    private func skillBinding(_ choice: NativKitSkillChoice) -> Binding<Bool> {
        let references = Set(choice.allReferences)
        return Binding(
            get: {
                !references.isDisjoint(with: draft.contents.skillReferences)
            },
            set: { selected in
                draft.contents.skillReferences.removeAll { references.contains($0) }
                if selected {
                    draft.contents.skillReferences.append(choice.reference)
                }
            }
        )
    }

    private func containsBinding<Value: Hashable>(
        _ value: Value,
        in keyPath: WritableKeyPath<NativKitContents, [Value]>
    ) -> Binding<Bool> {
        Binding(
            get: { draft.contents[keyPath: keyPath].contains(value) },
            set: { selected in
                if selected {
                    if !draft.contents[keyPath: keyPath].contains(value) {
                        draft.contents[keyPath: keyPath].append(value)
                    }
                } else {
                    draft.contents[keyPath: keyPath].removeAll { $0 == value }
                }
            }
        )
    }

    @ViewBuilder
    private func unavailableMCPSelections(known: Set<NativKitMCPServerReference>) -> some View {
        let unavailable = draft.contents.mcpSelections.filter { !known.contains($0.server) }
        if !unavailable.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("UNAVAILABLE SELECTIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(unavailable) { selection in
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(inventory.serverName(selection.server))
                        Spacer()
                        Button("Remove") {
                            draft.contents.mcpSelections.removeAll { $0.server == selection.server }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func unavailableToolSelections(choices: [NativKitToolChoice]) -> some View {
        let nativeNames = Set(choices.compactMap { choice -> String? in
            guard case .native = choice.source else { return nil }
            return String(choice.id.dropFirst("native:".count))
        })
        let customIDs = Set(choices.compactMap(\.customToolID))
        let missingNative = draft.contents.nativeToolNames.filter { !nativeNames.contains($0) }
        let missingCustom = draft.contents.customToolIDs.filter { !customIDs.contains($0) }
        if !missingNative.isEmpty || !missingCustom.isEmpty {
            unavailableHeader
            ForEach(missingNative, id: \.self) { name in
                unavailableRow(title: humanized(name)) {
                    draft.contents.nativeToolNames.removeAll { $0 == name }
                }
            }
            ForEach(missingCustom, id: \.self) { id in
                unavailableRow(title: "Removed custom tool") {
                    draft.contents.customToolIDs.removeAll { $0 == id }
                }
            }
        }
    }

    @ViewBuilder
    private func unavailableSkillSelections(known: Set<NativKitSkillReference>) -> some View {
        let missing = draft.contents.skillReferences.filter { !known.contains($0) }
        if !missing.isEmpty {
            unavailableHeader
            ForEach(missing, id: \.self) { reference in
                unavailableRow(title: skillName(reference)) {
                    draft.contents.skillReferences.removeAll { $0 == reference }
                }
            }
        }
    }

    private var unavailableHeader: some View {
        Text("UNAVAILABLE SELECTIONS")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 12)
    }

    private func unavailableRow(title: String, onRemove: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(title)
            Spacer()
            Button("Remove", action: onRemove)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
    }

    private func skillName(_ reference: NativKitSkillReference) -> String {
        switch reference {
        case .builtIn(let id): CustomNativKitCatalog.builtInSkill(id: id)?.name ?? humanized(id)
        case .configured: "Removed skill"
        }
    }

    private func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func matches(_ title: String, detail: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || detail.localizedCaseInsensitiveContains(query)
    }

    private func emptyState(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

private struct CapabilitySelectionRow: View {
    let title: String
    let detail: String
    let readiness: NativKitCapabilityReadiness
    let isOn: Binding<Bool>
    var onOpenCapability: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            NativKitReadinessLabel(
                readiness: readiness,
                onOpenCapability: onOpenCapability
            )
        }
    }
}

struct NativKitReadinessLabel: View {
    let readiness: NativKitCapabilityReadiness
    var onOpenCapability: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch readiness {
        case .ready:
            EmptyView()
        case .needsConfiguration:
            if let onOpenCapability {
                Button(action: onOpenCapability) {
                    label
                }
                .buttonStyle(.plain)
                .help("Open setup")
            } else {
                label
            }
        default:
            label
        }
    }

    private var label: some View {
        Text(readiness.label ?? "")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var color: Color {
        switch readiness {
        case .ready: .green
        case .connecting: .orange
        case .off: Color(nsColor: .secondaryLabelColor)
        case .needsConfiguration: .orange
        case .unavailable: .red
        }
    }
}
