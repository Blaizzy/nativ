import NativTrace
import SwiftUI

/// What one model call put in front of the model.
///
/// Collapsed by default and summarised by counts, because the interesting
/// question is usually "what changed" rather than "what is the whole prompt".
/// Expanding walks down: sections, then a section's text; tools, then a tool's
/// schema.
struct TraceExposureCard: View {
    let exposure: ResolvedExposure
    let diff: TraceExposureDiff
    let round: Int?
    let modelID: String?
    var isHighlighted = false

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(TracePalette.stroke)
                VStack(alignment: .leading, spacing: 14) {
                    systemPrompt
                    tools
                    if !exposure.messages.isEmpty { messages }
                    if !exposure.omissions.isEmpty { omissions }
                    parameters
                }
                .padding(14)
            }
        }
        .nativPanelStyle(cornerRadius: .large, isHighlighted: isHighlighted)
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Text(TraceCallLabel.title(round: round))
                    .font(.callout.weight(.semibold))

                Text("\(exposure.systemSections.count) prompt \(exposure.systemSections.count == 1 ? "section" : "sections") · \(toolSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                TraceDiffBadges(diff: diff)

                if let modelID {
                    Text(modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide what this call showed the model" : "Show what this call showed the model")
    }

    private var toolSummary: String {
        guard exposure.advertisesTools else { return "no tools offered" }
        return "\(exposure.tools.count) \(exposure.tools.count == 1 ? "tool" : "tools")"
    }

    private var systemPrompt: some View {
        TraceDisclosureSection(
            title: "System prompt",
            subtitle: "\(exposure.systemSections.count) sections",
            startsExpanded: true
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(exposure.systemSections.enumerated()), id: \.offset) { _, section in
                    TraceSectionRow(section: section, isEdited: diff.editedSections.contains(section))
                }
            }
        }
    }

    private var tools: some View {
        TraceDisclosureSection(
            title: "Tools exposed",
            subtitle: exposure.advertisesTools ? "\(exposure.tools.count)" : "withheld this round",
            startsExpanded: true
        ) {
            if exposure.tools.isEmpty {
                Text("No tools were advertised on this call.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(exposure.tools, id: \.name) { tool in
                        TraceToolDescriptorRow(
                            tool: tool,
                            change: change(for: tool)
                        )
                    }
                }
            }
        }
    }

    private var messages: some View {
        TraceDisclosureSection(
            title: "Conversation sent",
            subtitle: "\(exposure.messages.count) messages"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(exposure.messages) { message in
                    TraceResolvedMessageRow(message: message)
                }
            }
        }
    }

    private var omissions: some View {
        TraceDisclosureSection(title: "Left out", subtitle: "\(exposure.omissions.count)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(exposure.omissions, id: \.subject) { omission in
                    Text("\(omission.subject) — \(omission.reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var parameters: some View {
        TraceDisclosureSection(title: "Sampling", subtitle: nil) {
            TraceParameterGrid(parameters: exposure.parameters)
        }
    }

    private func change(for tool: ToolDescriptor) -> TraceToolChange {
        if diff.addedTools.contains(where: { $0.name == tool.name }) { return .added }
        if diff.redefinedTools.contains(where: { $0.name == tool.name }) { return .redefined }
        return .unchanged
    }
}
