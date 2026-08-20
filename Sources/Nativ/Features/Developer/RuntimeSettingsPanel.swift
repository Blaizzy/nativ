import NativServerKit
import SwiftUI

struct RuntimeSettingsPanel: View {
    @ObservedObject var store: RuntimeSettingsStore
    @State private var confirmingReload = false
    @State private var confirmingRestoreDefaults = false

    private static let controlWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if !isCollapsed {
                Divider()

                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .confirmationDialog(
            "Apply settings that reload models?",
            isPresented: $confirmingReload,
            titleVisibility: .visible
        ) {
            Button("Apply and Reload") {
                Task { await store.apply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(reloadWarningMessage)
        }
        .confirmationDialog(
            "Restore server defaults?",
            isPresented: $confirmingRestoreDefaults,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                Task { await store.restoreServerDefaults() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every live setting returns to the value the server started with. "
                    + "Loaded models reload."
            )
        }
    }

    private var isCollapsed: Bool {
        store.state == .unsupported
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 1) {
                Text("Live Server Settings")
                    .font(.callout.weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 24)

            headerActions
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if store.isApplying {
            ProgressView()
                .controlSize(.small)
        }

        headerStatus

        if case .loaded = store.state {
            Button("Discard") {
                store.discardChanges()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!store.isDirty || store.isApplying)

            Button("Apply") {
                if store.reloadWarningKinds.isEmpty {
                    Task { await store.apply() }
                } else {
                    confirmingReload = true
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!store.isDirty || store.isApplying)
        }

        Menu {
            Button("Reload from Server") {
                Task { await store.load() }
            }
            if case .loaded = store.state {
                Divider()
                Button("Restore Defaults…", role: .destructive) {
                    confirmingRestoreDefaults = true
                }
                .disabled(store.isApplying)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Reload or restore defaults")
        .disabled(store.isApplying)
    }

    @ViewBuilder
    private var headerStatus: some View {
        if store.isDirty {
            Text(changeSummary)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let appliedNotice = store.appliedNotice {
            Label(appliedNotice, systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var headerSubtitle: String {
        switch store.state {
        case .idle, .loading:
            return "Reading settings…"
        case .unsupported:
            return "Needs a newer bundled server to change without a restart"
        case .failed:
            return "Unavailable"
        case .loaded:
            return "No server restart required"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading settings…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .unsupported:
            notice(
                symbol: "info.circle",
                tint: .secondary,
                text: "This server build does not expose /v1/settings. Update the bundled "
                    + "server to change these without a restart."
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                notice(symbol: "exclamationmark.triangle", tint: .orange, text: message)
                Button("Try Again") {
                    Task { await store.load() }
                }
                .controlSize(.small)
            }

        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.groups) { group in
                groupSection(group)
            }

            if let applyError = store.applyError {
                notice(symbol: "exclamationmark.triangle", tint: .orange, text: applyError)
            }

            if !store.rejections.isEmpty {
                rejectionNotice
            }
        }
    }

    private func groupSection(_ group: RuntimeSettingGroup) -> some View {
        let fields = store.fields(in: group)
        let active = fields.filter { store.isActive($0) }
        let inactive = fields.filter { !store.isActive($0) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !active.isEmpty {
                fieldGrid(active)
            }

            if !inactive.isEmpty {
                DisclosureGroup {
                    fieldGrid(inactive)
                        .padding(.top, 4)
                } label: {
                    Text(disclosureLabel(count: inactive.count, group: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
    }

    private func disclosureLabel(count: Int, group: RuntimeSettingGroup) -> String {
        let noun = count == 1 ? "option" : "options"
        if let hint = store.inactiveHint(for: group) {
            return "\(count) more \(noun) · \(hint)"
        }
        return "\(count) more \(noun)"
    }

    private func fieldGrid(_ fields: [RuntimeSettingField]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 4) {
            ForEach(fields) { field in
                GridRow {
                    label(for: field)
                    RuntimeSettingControlCell(
                        field: field,
                        store: store,
                        controlWidth: Self.controlWidth
                    )
                }
            }
        }
    }

    private func label(for field: RuntimeSettingField) -> some View {
        let active = store.isActive(field)
        return HStack(spacing: 7) {
            Circle()
                .fill(field.isDirty ? Color.orange : Color.clear)
                .frame(width: 6, height: 6)

            Text(field.shortTitle)
                .font(.footnote.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .help(field.spec.help)
        .gridColumnAlignment(.leading)
    }

    private var rejectionNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.rejections) { rejection in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text("\(rejection.name): \(rejection.reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var changeSummary: String {
        let count = store.dirtyFields.count
        return count == 1 ? "1 change" : "\(count) changes"
    }

    private var reloadWarningMessage: String {
        "Applying reloads \(reloadKindsText). In-flight requests finish first, and the next "
            + "request waits for the model to load again."
    }

    private var reloadKindsText: String {
        let readable = store.reloadWarningKinds.map {
            $0.replacingOccurrences(of: "_", with: " ")
        }
        if readable.count <= 1 {
            return readable.first ?? "loaded models"
        }
        return readable.dropLast().joined(separator: ", ") + " and " + (readable.last ?? "")
    }

    private func notice(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuntimeSettingControlCell: View {
    let field: RuntimeSettingField
    @ObservedObject var store: RuntimeSettingsStore
    let controlWidth: CGFloat

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var isActive: Bool { store.isActive(field) }

    var body: some View {
        HStack(spacing: 6) {
            control
                .frame(width: controlWidth, alignment: .trailing)

            Text(field.unitSuffix ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            resetButton
                .frame(width: 16)
        }
        .disabled(!isActive)
        .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private var resetButton: some View {
        if !field.isDefault && isActive {
            Button {
                store.resetToDefault(field.id)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Reset to \(field.spec.defaultValue.displayText)")
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.control {
        case .toggle:
            Toggle(
                "",
                isOn: Binding(
                    get: { field.value.boolValue ?? false },
                    set: { store.setValue(.bool($0), for: field.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

        case .choice(let options):
            Picker(
                "",
                selection: Binding(
                    get: { field.value.stringValue ?? defaultChoiceTag },
                    set: { selection in
                        store.setValue(
                            selection == defaultChoiceTag ? .null : .string(selection),
                            for: field.id
                        )
                    }
                )
            ) {
                if field.spec.allowsNull {
                    Text(field.resolvedHint).tag(defaultChoiceTag)
                }
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.small)

        case .number(let isInteger):
            numberField(isInteger: isInteger)

        case .text:
            textField
        }
    }

    private var defaultChoiceTag: String { "\u{0000}default" }

    private func numberField(isInteger: Bool) -> some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.footnote.monospacedDigit())
            .controlSize(.small)
            .focused($isFocused)
            .onSubmit { commitNumber(isInteger: isInteger) }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    draft = editableText
                } else {
                    commitNumber(isInteger: isInteger)
                }
            }
            .onChange(of: field.value) { _, _ in
                if !isFocused { draft = editableText }
            }
            .onAppear { draft = editableText }
    }

    private var textField: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.footnote)
            .controlSize(.small)
            .focused($isFocused)
            .onSubmit(commitText)
            .onChange(of: isFocused) { _, focused in
                if focused {
                    draft = editableText
                } else {
                    commitText()
                }
            }
            .onChange(of: field.value) { _, _ in
                if !isFocused { draft = editableText }
            }
            .onAppear { draft = editableText }
    }

    private var placeholder: String {
        field.value.isNull ? field.resolvedHint : ""
    }

    private var editableText: String {
        field.value.isNull ? "" : field.value.displayText
    }

    private func commitNumber(isInteger: Bool) {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            store.setValue(field.spec.allowsNull ? .null : field.spec.defaultValue, for: field.id)
            return
        }
        if isInteger, let parsed = Int(trimmed) {
            store.setValue(.int(parsed), for: field.id)
        } else if let parsed = Double(trimmed) {
            store.setValue(isInteger ? .int(Int(parsed)) : .double(parsed), for: field.id)
        } else {
            draft = editableText
        }
    }

    private func commitText() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            store.setValue(field.spec.allowsNull ? .null : .string(""), for: field.id)
        } else {
            store.setValue(.string(trimmed), for: field.id)
        }
    }
}
