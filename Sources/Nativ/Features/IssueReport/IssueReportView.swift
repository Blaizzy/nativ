import AppKit
import SwiftUI

struct IssueReportView: View {
    @ObservedObject var model: NativModel
    @ObservedObject var runtime: SystemRuntimeMonitor
    @Environment(\.dismiss) private var dismiss

    @State private var category: IssueReportCategory = .modelDownload
    @State private var title = ""
    @State private var details = ""
    @State private var includeDiagnostics = true
    @State private var includeServerOutput = false
    @State private var showsCopiedConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    categoryPicker
                    titleField
                    detailsField
                    diagnosticsControls
                    reportPreview
                }
                .padding(18)
            }

            Divider()

            footer
        }
        .frame(width: 560, height: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Report an Issue", systemImage: "exclamationmark.bubble")
                .font(.title3.weight(.semibold))
            Text("Opens a prefilled GitHub issue — nothing is sent until you submit it there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What kind of issue?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Category", selection: $category) {
                ForEach(IssueReportCategory.allCases) { category in
                    Label(category.displayName, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Title")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Short summary of the problem", text: $title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var detailsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What happened")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if details.isEmpty {
                    Text(category.detailPrompt)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(minHeight: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
    }

    private var diagnosticsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include app diagnostics", isOn: $includeDiagnostics)
            Toggle("Include recent server output", isOn: $includeServerOutput)
                .disabled(model.logText.isEmpty)
        }
    }

    private var reportPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Report preview")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(reportMarkdown)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 170)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                dismiss()
            }

            Spacer()

            if showsCopiedConfirmation {
                Text("Copied")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            Button("Copy Report") {
                copyReport()
            }

            Button("Report on GitHub") {
                reportOnGitHub()
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedTitle.isEmpty)
            .help(trimmedTitle.isEmpty ? "Add a title first" : "Copies the full report and opens a prefilled GitHub issue")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var reportMarkdown: String {
        IssueReportBuilder.markdown(
            category: category,
            details: details,
            sections: includeDiagnostics
                ? IssueDiagnostics.collect(category: category, model: model, runtime: runtime)
                : [],
            serverOutput: includeServerOutput
                ? IssueDiagnostics.serverOutputTail(model: model)
                : []
        )
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportMarkdown, forType: .string)
        withAnimation {
            showsCopiedConfirmation = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                showsCopiedConfirmation = false
            }
        }
    }

    private func reportOnGitHub() {
        let markdown = reportMarkdown
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)

        guard let url = IssueReportBuilder.githubIssueURL(
            title: trimmedTitle,
            label: category.githubLabel,
            body: markdown
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
        dismiss()
    }
}
