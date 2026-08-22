import NativServerKit
import SwiftUI

struct RuntimeSettingsPanel: View {
    @ObservedObject var store: RuntimeSettingsStore
    @State private var confirmingReload = false
    @State private var confirmingRestoreDefaults = false

    private static let railWidth: CGFloat = 176
    private static let labelWidth: CGFloat = 116
    private static let valueWidth: CGFloat = 160
    private static let pathWidth: CGFloat = 360
    private static let unitWidth: CGFloat = 44

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
        .task(id: store.appliedNotice) {
            guard store.appliedNotice != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            store.dismissAppliedNotice()
        }
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 17, alignment: .leading)

                Text(group.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
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
                        Text(overriddenLabel(in: inactive))
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

    private func overriddenLabel(in fields: [RuntimeSettingField]) -> String {
        let overridden = fields.filter { !$0.isDefault }.count
        return overridden == 0 ? "Defaults" : "\(overridden) overridden"
    }

    private func fieldFlow(_ fields: [RuntimeSettingField]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                RuntimeSettingRow(
                    field: field,
                    store: store,
                    labelWidth: Self.labelWidth,
                    valueWidth: Self.valueWidth,
                    pathWidth: Self.pathWidth,
                    unitWidth: Self.unitWidth
                )
            }
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
            Text(changeSummary)
                .font(.caption.weight(.medium))
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

private struct RuntimeSettingRow: View {
    let field: RuntimeSettingField
    @ObservedObject var store: RuntimeSettingsStore
    let labelWidth: CGFloat
    let valueWidth: CGFloat
    let pathWidth: CGFloat
    let unitWidth: CGFloat

    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isActive: Bool { store.isActive(field) }

    private var isOverridden: Bool { !field.isDefault }

    private var controlWidth: CGFloat? {
        switch field.control {
        case .number, .combo:
            return valueWidth
        case .text:
            return pathWidth
        case .toggle, .choice:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(field.isDirty ? Color.orange : Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
                .opacity(isOverridden ? 1 : 0)

            Text(field.shortTitle)
                .font(.footnote)
                .foregroundStyle(labelColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
                .help(field.spec.help)

            Spacer(minLength: 12)

            resetButton

            control
                .frame(width: controlWidth, alignment: .trailing)

            Text(field.unitSuffix ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: unitWidth, alignment: .leading)
        }
        .disabled(!isActive)
        .onHover { isHovering = $0 }
    }

    private var labelColor: Color {
        if field.isDirty { return .orange }
        return isActive ? .primary : .secondary
    }

    private var showsReset: Bool {
        isOverridden && isActive
    }

    private var resetButton: some View {
        Button {
            store.resetToDefault(field.id)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .help("Reset to \(field.spec.defaultValue.displayText)")
        .frame(width: 16)
        .opacity(showsReset && (isHovering || isFocused) ? 1 : 0)
        .disabled(!showsReset)
        .accessibilityHidden(!showsReset)
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

        case .combo(let presets, let isInteger):
            HStack(spacing: 4) {
                editableField(alignment: .trailing, font: .footnote.monospacedDigit()) {
                    commitNumber(isInteger: isInteger)
                }

                Menu {
                    if field.spec.allowsNull {
                        Button(field.resolvedHint) {
                            store.setValue(.null, for: field.id)
                        }
                        Divider()
                    }
                    ForEach(presets, id: \.self) { preset in
                        Button(preset) {
                            commit(preset, isInteger: isInteger)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

        case .number(let isInteger):
            editableField(alignment: .trailing, font: .footnote.monospacedDigit()) {
                commitNumber(isInteger: isInteger)
            }

        case .text:
            editableField(alignment: .leading, font: .footnote, commit: commitText)
        }
    }

    private var defaultChoiceTag: String { "\u{0000}default" }

    private func editableField(
        alignment: TextAlignment,
        font: Font,
        commit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(alignment)
            .font(font)
            .foregroundStyle(.primary)
            .controlSize(.small)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if focused {
                    draft = editableText
                } else {
                    commit()
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

    private func commit(_ text: String, isInteger: Bool) {
        draft = text
        commitNumber(isInteger: isInteger)
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
