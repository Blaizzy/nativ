import NativServerKit
import SwiftUI

struct RuntimeSettingsPanel: View {
    @ObservedObject var store: RuntimeSettingsStore
    @State private var confirmingReload = false
    @State private var confirmingRestoreDefaults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            if !isCollapsed {
                Divider()

                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
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

            Spacer()

            if store.isApplying {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await store.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload settings from the server")
            .disabled(store.isApplying)
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
            return "Changes apply without restarting the server"
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

            if !store.rejections.isEmpty {
                rejectionNotice
            }

            footer
        }
    }

    private func groupSection(_ group: RuntimeSettingGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: group.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(store.fields(in: group)) { field in
                RuntimeSettingRow(field: field, store: store)
            }
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

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isDirty {
                Text(changeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !store.lastReloadKinds.isEmpty {
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()

            Button("Restore Defaults") {
                confirmingRestoreDefaults = true
            }
            .controlSize(.small)
            .disabled(store.isApplying)

            Button("Discard") {
                store.discardChanges()
            }
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
            .disabled(!store.isDirty || store.isApplying)
        }
    }

    private var changeSummary: String {
        let count = store.dirtyFields.count
        let noun = count == 1 ? "change" : "changes"
        guard !store.reloadWarningKinds.isEmpty else {
            return "\(count) pending \(noun)"
        }
        return "\(count) pending \(noun) — reloads \(reloadKindsText)"
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
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(field.title)
                        .font(.footnote.weight(.medium))

                    if field.isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .help("Changed — not applied yet")
                    }

                    if field.spec.reloadsModels {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Changing this reloads the affected models")
                    }
                }

                if !field.spec.help.isEmpty {
                    Text(field.spec.help)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control
                .frame(maxWidth: 190, alignment: .trailing)

            Button {
                store.resetToDefault(field.id)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Reset to \(field.spec.defaultValue.displayText)")
            .opacity(field.isDefault ? 0.25 : 1)
            .disabled(field.isDefault)
        }
        .padding(.vertical, 3)
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
                    Text("Default").tag(defaultChoiceTag)
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
        field.spec.allowsNull ? field.spec.defaultValue.displayText : ""
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
