import NativExtensionSDK
import NativServerKit
import SwiftUI

private struct KitStateIcon: View {
    let state: NativKitState

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Kit status: \(title)")
            .help(title)
    }

    private var title: String {
        switch state {
        case .off: "Not enabled"
        case .partial: "Partially enabled"
        case .enabled: "Enabled"
        }
    }

    private var symbol: String {
        switch state {
        case .off: "circle"
        case .partial: "circle.lefthalf.filled"
        case .enabled: "circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .off: .secondary
        case .partial: .orange
        case .enabled: .green
        }
    }
}

private enum KitSheet: Identifiable {
    case detail(NativKit)
    case editor(NativKit)

    var id: String {
        switch self {
        case .detail(let kit): "detail-\(kit.id)"
        case .editor(let kit): "editor-\(kit.id)"
        }
    }
}

struct KitsSectionView: View {
    @ObservedObject var manager: NativExtensionManager
    var model: NativModel
    @State private var presentedSheet: KitSheet?
    @State private var pendingDeletion: NativKit?
    @State private var errorMessage: String?

    private static let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14)]

    var body: some View {
        let catalog = model.kitLibrary.catalog
        HubSectionScaffold(
            title: "Kits",
            subtitle: "Reusable groups of MCP servers, tools, skills, and extensions. Enabling a Kit only turns on what is missing."
        ) {
            Button(action: createKit) {
                Label("Add Kit", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("Create a custom Kit")
            .accessibilityIdentifier("add-kit-button")
        } content: {
            if let message = model.kitLibrary.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                ForEach(catalog.kits) { kit in
                    kitCard(for: kit, catalog: catalog)
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .detail(let kit):
                KitDetailView(kit: kit, manager: manager, model: model)
            case .editor(let kit):
                NativKitEditorSheet(kit: kit, manager: manager, model: model)
            }
        }
        .alert("Delete Kit?", isPresented: deletionIsPresented) {
            Button("Delete", role: .destructive, action: deletePendingKit)
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the Kit definition. Its enabled capabilities stay enabled.")
        }
        .alert("Couldn’t Update Kits", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func kitCard(for kit: NativKit, catalog: NativKitCatalog) -> some View {
        let snapshot = NativKitActivation.snapshot(
            of: kit,
            model: model,
            kitCatalog: catalog,
            extensionName: extensionName,
            isExtensionEnabled: manager.isEnabled(extensionID:)
        )
        return KitCard(
            kit: kit,
            snapshot: snapshot,
            isBuiltIn: catalog.isBundled(kitID: kit.id),
            onOpen: { presentedSheet = .detail(kit) },
            onEnable: { enableMissing(in: kit) },
            onEdit: { presentedSheet = .editor(kit) },
            onDelete: { pendingDeletion = kit }
        )
    }

    private func createKit() {
        presentedSheet = .editor(NativKit(
            id: UUID().uuidString.lowercased(),
            name: "",
            summary: "",
            symbol: "shippingbox",
            tintName: "blue",
            components: []
        ))
    }

    private func enableMissing(in kit: NativKit) {
        NativKitActivation.enableMissing(
            in: kit,
            model: model,
            isExtensionEnabled: manager.isEnabled(extensionID:),
            enableExtension: { manager.setEnabled(true, extensionID: $0) }
        )
    }

    private func deletePendingKit() {
        guard let kit = pendingDeletion else { return }
        do {
            try model.kitLibrary.delete(kitID: kit.id)
            pendingDeletion = nil
        } catch {
            pendingDeletion = nil
            errorMessage = error.localizedDescription
        }
    }

    private func extensionName(_ id: String) -> String {
        manager.records.first { $0.id == id }?.manifest.displayName ?? id
    }
}

private struct KitCard: View {
    let kit: NativKit
    let snapshot: NativKitActivationSnapshot
    let isBuiltIn: Bool
    let onOpen: () -> Void
    let onEnable: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                NativTintedIconTile(symbol: kit.symbol, tint: .nativTint(kit.tintName))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                NativStatusBadge(text: isBuiltIn ? "Built-in" : "Custom")
                    .help(isBuiltIn ? "Ships with Nativ" : "Created by you")
                KitStateIcon(state: snapshot.state)
                if !isBuiltIn {
                    Menu {
                        Button("Edit", systemImage: "pencil", action: onEdit)
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Kit actions")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(kit.name)
                    .nativTextStyle(.cardTitle)
                if !kit.summary.isEmpty {
                    Text(kit.summary)
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(capabilitiesText)
                .nativTextStyle(.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .nativTextStyle(.supporting)
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var capabilitiesText: String {
        if snapshot.state == .partial {
            "Needs: \(snapshot.inactivePartNames.joined(separator: " · "))"
        } else {
            "Includes: \(kit.inventory)"
        }
    }

    @ViewBuilder
    private var actions: some View {
        if snapshot.state != .enabled {
            Button(snapshot.state == .partial ? "Enable Missing" : "Enable", action: onEnable)
                .buttonStyle(.borderedProminent)
        }
        Button(snapshot.state == .off ? "Details" : "Manage", action: onOpen)
            .buttonStyle(.bordered)
    }
}

private enum KitComponentSection: String, CaseIterable, Identifiable {
    case mcp = "MCP Servers"
    case tools = "Tools"
    case skills = "Skills"
    case extensions = "Extensions"

    var id: String { rawValue }
}

private struct KitComponentDescriptor: Identifiable {
    let component: NativKitComponent
    let section: KitComponentSection
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let logoAssetName: String?
    let isAvailable: Bool
    let isEnabled: Bool

    var id: String { component.id }
}

private struct KitDetailView: View {
    let kit: NativKit
    @ObservedObject var manager: NativExtensionManager
    var model: NativModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(KitComponentSection.allCases) { section in
                        let components = descriptors.filter { $0.section == section }
                        if !components.isEmpty {
                            KitGroup(title: section.rawValue, caption: caption(for: section)) {
                                ForEach(components) { descriptor in
                                    KitPartRow(
                                        descriptor: descriptor,
                                        isOn: binding(for: descriptor.component)
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationSizing(.fitted)
        .frame(
            minWidth: 600,
            idealWidth: 680,
            maxWidth: 920,
            minHeight: 480,
            idealHeight: 620,
            maxHeight: 800
        )
    }

    private var header: some View {
        let snapshot = NativKitActivation.snapshot(
            of: kit,
            model: model,
            extensionName: extensionName,
            isExtensionEnabled: manager.isEnabled(extensionID:)
        )
        return HStack(alignment: .top, spacing: 12) {
            NativTintedIconTile(symbol: kit.symbol, tint: .nativTint(kit.tintName), size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kit.name)
                        .nativTextStyle(.detailTitle)
                    KitStateIcon(state: snapshot.state)
                }
                if !kit.summary.isEmpty {
                    Text(kit.summary)
                        .nativTextStyle(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.state != .enabled {
                    Button(snapshot.state == .partial ? "Enable Missing" : "Enable All", action: enableAll)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            NativHoverCloseButton { dismiss() }
        }
        .padding(20)
    }

    private var descriptors: [KitComponentDescriptor] {
        kit.components.map(descriptor(for:))
    }

    private func descriptor(for component: NativKitComponent) -> KitComponentDescriptor {
        KitComponentInventory.descriptor(
            for: component,
            catalog: model.kitLibrary.catalog,
            settings: model.settings,
            records: manager.records
        )
    }

    private func caption(for section: KitComponentSection) -> String? {
        switch section {
        case .mcp: "These servers connect in Auto mode so agents can discover their tools."
        case .tools: "Built-in and custom tools included directly."
        case .skills: "Guidance added to the model when tools are available."
        case .extensions: nil
        }
    }

    private func binding(for component: NativKitComponent) -> Binding<Bool> {
        Binding(
            get: { descriptor(for: component).isEnabled },
            set: { setEnabled($0, component: component) }
        )
    }

    private func setEnabled(_ enabled: Bool, component: NativKitComponent) {
        switch component {
        case .mcpServer(.catalog(let id)):
            guard let entry = MCPServerCatalog.bundled.entry(id: id) else { return }
            var servers = model.settings.mcpServers
            MCPServerCatalog.bundled.setEnabled(enabled, for: entry, in: &servers)
            var settings = model.settings
            settings.mcpServers = servers
            if let server = MCPServerCatalog.bundled.configuredServer(for: entry, in: servers) {
                settings.setMCPServerExposureMode(enabled ? .automatic : .off, serverID: server.id)
            }
            model.settings = settings
        case .mcpServer(.configured(let id)):
            model.settings.setMCPServerExposureMode(enabled ? .automatic : .off, serverID: id)
        case .nativeTool(let name):
            model.settings.setToolExposureMode(
                enabled ? NativSettings.defaultToolExposureMode(for: name) : .off,
                toolName: name
            )
        case .customTool(let id):
            guard let tool = model.settings.customTools.first(where: { $0.id == id }) else { return }
            model.settings.setToolExposureMode(
                enabled ? .automatic : .off,
                toolName: tool.toolName
            )
        case .skill(let id):
            if let index = model.settings.skills.firstIndex(where: { $0.id == id }) {
                model.settings.skills[index].isEnabled = enabled
            } else if enabled, let skill = model.kitLibrary.catalog.skillDefinition(id: id) {
                model.settings.skills.append(skill)
            }
        case .extensionPackage(let id):
            manager.setEnabled(enabled, extensionID: id)
        }
    }

    private func enableAll() {
        NativKitActivation.enableMissing(
            in: kit,
            model: model,
            isExtensionEnabled: manager.isEnabled(extensionID:),
            enableExtension: { manager.setEnabled(true, extensionID: $0) }
        )
    }

    private func extensionName(_ id: String) -> String {
        manager.records.first { $0.id == id }?.manifest.displayName ?? id
    }
}

private enum KitEditorField: Hashable {
    case name
}

private struct NativKitEditorSheet: View {
    @ObservedObject var manager: NativExtensionManager
    var model: NativModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativKit
    @State private var selectedComponents: Set<NativKitComponent>
    @State private var query = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: KitEditorField?
    private let inventory: [KitComponentDescriptor]

    init(kit: NativKit, manager: NativExtensionManager, model: NativModel) {
        self.manager = manager
        self.model = model
        _draft = State(initialValue: kit)
        _selectedComponents = State(initialValue: Set(kit.components))
        inventory = KitComponentInventory.choices(
            selected: kit.components,
            catalog: model.kitLibrary.catalog,
            settings: model.settings,
            records: manager.records
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(editorTitle)
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)

                        KitEditorFields(
                            name: $draft.name,
                            summary: $draft.summary,
                            focusedField: $focusedField
                        )
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Capabilities")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("\(selectedComponents.count) selected")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if choiceGroups.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical)
                    } else {
                        ForEach(choiceGroups) { group in
                            KitEditorCapabilityGroup(
                                title: group.section.rawValue,
                                choices: group.choices,
                                selectedComponents: $selectedComponents
                            )
                        }
                    }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .scrollBounceBehavior(.basedOnSize)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
        }
        .searchable(text: $query, prompt: "Search capabilities")
        .defaultFocus($focusedField, .name)
        .presentationSizing(.fitted)
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: 980,
            minHeight: 520,
            idealHeight: 680,
            maxHeight: 900
        )
        .alert("Couldn’t Save Kit", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var editorTitle: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return "Make Kit"
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedComponents.isEmpty
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var filteredChoices: [KitComponentDescriptor] {
        guard !query.isEmpty else { return inventory }
        return inventory.filter {
            $0.title.localizedStandardContains(query)
                || ($0.subtitle?.localizedStandardContains(query) == true)
        }
    }

    private var choiceGroups: [KitEditorChoiceGroup] {
        let visibleChoices = filteredChoices
        return KitComponentSection.allCases.compactMap { section in
            let choices = visibleChoices.filter { $0.section == section }
            return choices.isEmpty ? nil : KitEditorChoiceGroup(section: section, choices: choices)
        }
    }

    private func save() {
        do {
            var kit = draft
            kit.components = inventory
                .map(\.component)
                .filter(selectedComponents.contains)
            try model.kitLibrary.upsert(kit)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct KitEditorChoiceGroup: Identifiable {
    let section: KitComponentSection
    let choices: [KitComponentDescriptor]

    var id: KitComponentSection { section }
}

private struct KitEditorFields: View {
    @Binding var name: String
    @Binding var summary: String
    var focusedField: FocusState<KitEditorField?>.Binding

    var body: some View {
        KitEditorSectionSurface {
            TextField("Kit name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused(focusedField, equals: .name)

            TextField("What is this Kit for?", text: $summary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
        }
    }
}

private struct KitEditorCapabilityGroup: View {
    let title: String
    let choices: [KitComponentDescriptor]
    @Binding var selectedComponents: Set<NativKitComponent>

    var body: some View {
        KitEditorSectionSurface {
            Text(title)
                .font(.headline)

            VStack {
                ForEach(choices) { choice in
                    KitMembershipRow(
                        descriptor: choice,
                        selectedComponents: $selectedComponents
                    )
                }
            }
        }
    }
}

private struct KitEditorSectionSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading) {
            content()
        }
        .padding()
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct KitMembershipRow: View {
    let descriptor: KitComponentDescriptor
    @Binding var selectedComponents: Set<NativKitComponent>

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(descriptor.title, isOn: isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
                .accessibilityIdentifier("kit-component-\(descriptor.id)")

            KitMembershipIcon(descriptor: descriptor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.title)
                if let subtitle = descriptor.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)

            if !descriptor.isAvailable {
                Label("Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            selectedComponents.contains(descriptor.component)
                ? Color.accentColor.opacity(0.08)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var isIncluded: Binding<Bool> {
        Binding(
            get: { selectedComponents.contains(descriptor.component) },
            set: { included in
                if included {
                    selectedComponents.insert(descriptor.component)
                } else {
                    selectedComponents.remove(descriptor.component)
                }
            }
        )
    }

    private var accessibilityLabel: String {
        descriptor.isAvailable ? descriptor.title : "\(descriptor.title), unavailable"
    }

    private var accessibilityHint: String {
        if !descriptor.isAvailable {
            return "Deselect this capability to remove its unavailable reference."
        }
        return descriptor.subtitle ?? ""
    }
}

private struct KitMembershipIcon: View {
    let descriptor: KitComponentDescriptor

    var body: some View {
        Group {
            if let logoAssetName = descriptor.logoAssetName,
               let image = NSImage(named: logoAssetName) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: descriptor.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(descriptor.tint)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct KitGroup<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .nativTextStyle(.sectionTitle)
                if let caption {
                    Text(caption)
                        .nativTextStyle(.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) { content() }
        }
    }
}

private struct KitPartRow: View {
    let descriptor: KitComponentDescriptor
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                NativTintedIconTile(
                    symbol: descriptor.symbol,
                    tint: descriptor.tint,
                    logoAssetName: descriptor.logoAssetName,
                    size: 30
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.title)
                        .nativTextStyle(.rowTitle)
                    if let subtitle = descriptor.subtitle {
                        Text(subtitle)
                            .nativTextStyle(.metadata)
                            .foregroundStyle(descriptor.isAvailable ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .disabled(!descriptor.isAvailable)
        .padding(.vertical, 8)
    }
}

private enum KitComponentInventory {
    static func choices(
        selected: [NativKitComponent],
        catalog: NativKitCatalog,
        settings: NativSettings,
        records: [NativExtensionRecord]
    ) -> [KitComponentDescriptor] {
        var components = MCPServerCatalog.bundled.entries.map {
            NativKitComponent.mcpServer(.catalog(id: $0.id))
        }
        components += settings.mcpServers
            .filter { MCPServerCatalog.bundled.entry(matching: $0) == nil }
            .map { .mcpServer(.configured(id: $0.id)) }
        components += ChatToolRegistry.descriptors(canEditImage: false)
            .filter { $0.definition.function.name != ChatSwitchModelToolRegistry.toolName }
            .map { .nativeTool(name: $0.definition.function.name) }
        components += settings.customTools.map { .customTool(id: $0.id) }

        var skillIDs = Set<UUID>()
        for skill in catalog.skillDefinitions + settings.skills where skillIDs.insert(skill.id).inserted {
            components.append(.skill(id: skill.id))
        }
        components += records.filter { !$0.isRemoved }.map { .extensionPackage(id: $0.id) }

        let knownIDs = Set(components.map(\.id))
        components += selected.filter { !knownIDs.contains($0.id) }

        return components
            .map {
                descriptor(
                    for: $0,
                    catalog: catalog,
                    settings: settings,
                    records: records
                )
            }
            .sorted {
                if $0.section != $1.section {
                    return KitComponentSection.allCases.firstIndex(of: $0.section)!
                        < KitComponentSection.allCases.firstIndex(of: $1.section)!
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    static func descriptor(
        for component: NativKitComponent,
        catalog: NativKitCatalog,
        settings: NativSettings,
        records: [NativExtensionRecord]
    ) -> KitComponentDescriptor {
        switch component {
        case .mcpServer(.catalog(let id)):
            guard let entry = MCPServerCatalog.bundled.entry(id: id) else {
                return unavailable(component, section: .mcp, title: id)
            }
            return KitComponentDescriptor(
                component: component,
                section: .mcp,
                title: entry.name,
                subtitle: entry.summary,
                symbol: entry.symbol,
                tint: .nativTint(entry.tintName),
                logoAssetName: entry.logoAssetName,
                isAvailable: true,
                isEnabled: MCPServerCatalog.bundled.isEnabled(entry, in: settings.mcpServers)
            )
        case .mcpServer(.configured(let id)):
            guard let server = settings.mcpServers.first(where: { $0.id == id }) else {
                return unavailable(component, section: .mcp, title: "MCP Server")
            }
            return KitComponentDescriptor(
                component: component,
                section: .mcp,
                title: server.name.isEmpty ? "MCP Server" : server.name,
                subtitle: server.command,
                symbol: "server.rack",
                tint: .accentColor,
                logoAssetName: nil,
                isAvailable: true,
                isEnabled: server.isEnabled
            )
        case .nativeTool(let name):
            let descriptor = ChatToolRegistry.descriptors(canEditImage: false)
                .first { $0.definition.function.name == name }
            guard let descriptor else {
                return unavailable(component, section: .tools, title: humanized(name))
            }
            return KitComponentDescriptor(
                component: component,
                section: .tools,
                title: descriptor.configuration?.displayName ?? humanized(name),
                subtitle: descriptor.displayDescription,
                symbol: "hammer",
                tint: .accentColor,
                logoAssetName: nil,
                isAvailable: true,
                isEnabled: settings.isToolEnabled(name)
            )
        case .customTool(let id):
            guard let tool = settings.customTools.first(where: { $0.id == id }) else {
                return unavailable(component, section: .tools, title: "Custom Tool")
            }
            return KitComponentDescriptor(
                component: component,
                section: .tools,
                title: tool.name,
                subtitle: tool.displaySummary,
                symbol: "wrench.and.screwdriver",
                tint: .accentColor,
                logoAssetName: nil,
                isAvailable: true,
                isEnabled: settings.isToolEnabled(tool.toolName)
            )
        case .skill(let id):
            let skill = settings.skills.first(where: { $0.id == id }) ?? catalog.skillDefinition(id: id)
            guard let skill else {
                return unavailable(component, section: .skills, title: "Skill")
            }
            return KitComponentDescriptor(
                component: component,
                section: .skills,
                title: skill.name,
                subtitle: skill.instructions,
                symbol: "sparkles",
                tint: .purple,
                logoAssetName: nil,
                isAvailable: true,
                isEnabled: settings.skills.first(where: { $0.id == id })?.isEnabled == true
            )
        case .extensionPackage(let id):
            guard let record = records.first(where: { $0.id == id && !$0.isRemoved }) else {
                return unavailable(component, section: .extensions, title: id)
            }
            return KitComponentDescriptor(
                component: component,
                section: .extensions,
                title: record.manifest.displayName,
                subtitle: record.manifest.summary,
                symbol: record.manifest.systemImage,
                tint: .accentColor,
                logoAssetName: nil,
                isAvailable: record.hasRuntime,
                isEnabled: record.isEnabled && record.hasRuntime
            )
        }
    }

    private static func unavailable(
        _ component: NativKitComponent,
        section: KitComponentSection,
        title: String
    ) -> KitComponentDescriptor {
        KitComponentDescriptor(
            component: component,
            section: section,
            title: title,
            subtitle: "Unavailable — remove this reference or restore its capability.",
            symbol: "exclamationmark.triangle",
            tint: .orange,
            logoAssetName: nil,
            isAvailable: false,
            isEnabled: false
        )
    }

    private static func humanized(_ name: String) -> String {
        name.split(separator: "_").map { String($0).capitalized }.joined(separator: " ")
    }
}
