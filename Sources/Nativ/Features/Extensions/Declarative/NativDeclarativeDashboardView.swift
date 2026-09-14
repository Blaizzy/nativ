import NativExtensionSDK
import SwiftUI

struct NativDeclarativeDashboardView: View {
    let runtime: NativDeclarativeExtension
    let dashboard: NativExtensionDashboard
    let titleLeadingInset: CGFloat
    @State private var selectedTab: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dashboard.title).font(.title2.weight(.semibold))
                Text(runtime.manifest.summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.leading, titleLeadingInset)
            .controlPanelDetailHeaderTopPadding()
            .padding(.bottom, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dashboard.tabs) { tab in
                        Button(tab.title) { selectedTab = tab.id }
                            .buttonStyle(.bordered)
                            .tint(currentTab?.id == tab.id ? .accentColor : .secondary)
                            .accessibilityAddTraits(currentTab?.id == tab.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = runtime.workspace?.loadError ?? runtime.workspace?.errorMessage ?? runtime.runError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let tab = currentTab {
                        ForEach(tab.sections) { section in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(section.components) { component in
                                        NativDashboardComponentView(component: component, runtime: runtime)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            } label: {
                                Text(section.title).font(.headline)
                            }
                        }
                    }
                }
                .padding(22)
            }
            if runtime.workflow != nil {
                Divider()
                HStack {
                    if runtime.isRunning {
                        ProgressView(value: Double(runtime.completedSteps), total: Double(max(runtime.totalSteps, 1)))
                            .frame(width: 120)
                            .accessibilityLabel("Command progress")
                    }
                    Text(runtime.status).foregroundStyle(.secondary)
                    Spacer()
                    if runtime.isRunning {
                        Button("Cancel") { runtime.cancel() }
                    }
                }
                .padding(16)
            }
        }
        .disabled(!runtime.isActive)
    }

    private var currentTab: NativDashboardTab? {
        dashboard.tabs.first(where: { $0.id == selectedTab }) ?? dashboard.tabs.first
    }
}

private struct NativDashboardComponentView: View {
    let component: NativDashboardComponent
    let runtime: NativDeclarativeExtension

    private var value: NativWorkflowValue {
        runtime.workspace?.values[component.storageKey ?? ""] ?? .none
    }

    var body: some View {
        Group {
            switch component.type {
            case .text:
                VStack(alignment: .leading, spacing: 6) {
                    Text(component.title).font(.subheadline.weight(.medium))
                    Text(component.text ?? NativWorkflowRunner.scalarText(value))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .textField:
                NativDashboardField(component: component, runtime: runtime)
            case .toggle:
                Toggle(component.title, isOn: Binding(
                    get: { if case .boolean(let flag) = value { return flag }; return false },
                    set: { runtime.setValue(.boolean($0), for: component.storageKey ?? "") }
                ))
            case .picker:
                Picker(component.title, selection: Binding(
                    get: { value.text ?? "" },
                    set: { runtime.setValue(.text($0), for: component.storageKey ?? "") }
                )) {
                    if let current = value.text, !(component.options ?? []).contains(current) {
                        Text("\(current) (unavailable)").tag(current)
                    }
                    ForEach(component.options ?? [], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            case .button:
                Button(component.title) { runtime.performCommand(id: component.commandID ?? "") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(runtime.isRunning || runtime.workspace?.loadError != nil)
    }
}

private struct NativDashboardField: View {
    let component: NativDashboardComponent
    let runtime: NativDeclarativeExtension
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var key: String { component.storageKey ?? "" }
    private var storedText: String { NativWorkflowRunner.scalarText(runtime.workspace?.values[key] ?? .none) }

    var body: some View {
        TextField(component.title, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { draft = storedText }
            .onSubmit { save() }
            .onChange(of: draft) { _, _ in save() }
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            .onChange(of: storedText) { _, text in
                if !isFocused { draft = text }
            }
            .onDisappear { save() }
    }

    private func save() {
        guard draft != storedText else { return }
        if runtime.dashboard?.storage[key]?.type == .number {
            guard let number = Double(draft), number.isFinite else {
                runtime.workspace?.errorMessage = "Enter a valid number for \(component.title)."
                return
            }
            runtime.setValue(.number(number), for: key)
        } else {
            runtime.setValue(.text(draft), for: key)
        }
    }
}
