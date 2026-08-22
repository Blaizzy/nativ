import NativServerKit
import SwiftUI

struct RuntimeSettingsPanel: View {
    @ObservedObject var store: RuntimeSettingsStore
    @State private var confirmingReload = false
    @State private var confirmingRestoreDefaults = false

    private static let railWidth: CGFloat = 152
    private static let labelWidth: CGFloat = 116
    private static let controlWidth: CGFloat = 150
    private static let unitWidth: CGFloat = 48
    private static let fieldColumnWidth: CGFloat = 348

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if !isCollapsed {
                Divider()
                content
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            Spacer(minLength: 16)

            if store.isApplying {
                ProgressView()
                    .controlSize(.small)
            }

            overflowMenu
        }
    }

    private var overflowMenu: some View {
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

    private var headerSubtitle: String {
        switch store.state {
        case .idle, .loading:
            return "Reading settings…"
        case .unsupported:
            return "Needs a newer bundled server to change without a restart"
        case .failed:
            return "Unavailable"
        case .loaded:
            return "Changes take effect without a server restart"
        }
    }

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
            .padding(12)

        case .unsupported:
            EmptyView()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                notice(symbol: "exclamationmark.triangle", tint: .orange, text: message)
                Button("Try Again") {
                    Task { await store.load() }
                }
                .controlSize(.small)
            }
            .padding(12)

        case .loaded:
            VStack(spacing: 0) {
                ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 {
                        Divider()
                    }
                    band(group)
                }

                if let applyError = store.applyError {
                    Divider()
                    notice(symbol: "exclamationmark.triangle", tint: .orange, text: applyError)
                        .padding(12)
                }

                if !store.rejections.isEmpty {
                    Divider()
                    rejectionNotice
                        .padding(12)
                }
            }
        }
    }

    private func band(_ group: RuntimeSettingGroup) -> some View {
        let fields = store.fields(in: group)
        let active = fields.filter { store.isActive($0) }
        let inactive = fields.filter { !store.isActive($0) }

        return HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: group.symbol)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, alignment: .leading)

                Text(group.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: Self.railWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if !active.isEmpty {
                    fieldFlow(active)
                }

                if !inactive.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            if let hint = store.inactiveHint(for: group) {
                                Text(hint.prefix(1).uppercased() + hint.dropFirst())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            fieldFlow(inactive)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(disclosureLabel(count: inactive.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func disclosureLabel(count: Int) -> String {
        count == 1 ? "1 more option" : "\(count) more options"
    }

    private func fieldFlow(_ fields: [RuntimeSettingField]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Self.fieldColumnWidth), spacing: 20)],
            alignment: .leading,
            spacing: 7
        ) {
            ForEach(fields) { field in
                fieldRow(field)
            }
        }
    }

    private func fieldRow(_ field: RuntimeSettingField) -> some View {
        HStack(spacing: 10) {
            Text(field.shortTitle)
                .font(.footnote)
                .foregroundStyle(store.isActive(field) ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.labelWidth, alignment: .leading)
                .help(field.spec.help)

            RuntimeSettingControlCell(
                field: field,
                store: store,
                controlWidth: Self.controlWidth,
                unitWidth: Self.unitWidth
            )
        }
    }

    @ViewBuilder
    private var footer: some View {
        if case .loaded = store.state, store.isDirty || store.appliedNotice != nil {
            Divider()

            HStack(spacing: 10) {
                footerStatus

                Spacer(minLength: 12)

                if store.isDirty {
                    Button("Discard") {
                        store.discardChanges()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(store.isApplying)

                    Button("Apply") {
                        if store.reloadWarningKinds.isEmpty {
                            Task { await store.apply() }
                        } else {
                            confirmingReload = true
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isApplying)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var footerStatus: some View {
        if store.isDirty {
            Label(changeSummary, systemImage: "circle.fill")
                .labelStyle(DotLabelStyle())
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let appliedNotice = store.appliedNotice {
            Label(appliedNotice, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
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
        return count == 1 ? "1 unapplied change" : "\(count) unapplied changes"
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

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 6))
            configuration.title
        }
    }
}

private struct RuntimeSettingControlCell: View {
    let field: RuntimeSettingField
    @ObservedObject var store: RuntimeSettingsStore
    let controlWidth: CGFloat
    let unitWidth: CGFloat

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var isActive: Bool { store.isActive(field) }

    private var stretchesToFill: Bool {
        if case .text = field.control { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            if stretchesToFill {
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                control
                    .frame(width: controlWidth, alignment: .leading)

                Text(field.unitSuffix ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: unitWidth, alignment: .leading)
            }

            resetButton
        }
        .disabled(!isActive)
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
            .frame(width: 16)
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
