import NativTrace
import SwiftUI

enum TracePalette {
    static let stroke = Color(nsColor: .separatorColor).opacity(0.6)
    static let added = Color(red: 62 / 255, green: 179 / 255, blue: 131 / 255)
    static let removed = Color(red: 225 / 255, green: 91 / 255, blue: 101 / 255)
    static let changed = Color(red: 232 / 255, green: 151 / 255, blue: 65 / 255)
    static let accent = Color(red: 71 / 255, green: 151 / 255, blue: 232 / 255)
}

enum TraceCallLabel {
    /// `index` counts calls within a trace; `round` counts them within a turn
    /// and restarts at zero each time, so it cannot number the list on its own.
    static func title(index: Int, round: Int?) -> String {
        guard let round, round > 0 else { return "Call \(index)" }
        return "Call \(index) · round \(round + 1)"
    }
}

enum TraceToolChange {
    case added
    case redefined
    case unchanged
}

/// A titled, collapsible block inside the exposure card.
struct TraceDisclosureSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    @State private var isExpanded: Bool

    init(
        title: String,
        subtitle: String?,
        startsExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.callout.weight(.medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content.padding(.leading, 16)
            }
        }
    }
}

/// One provenance-labelled span of the system prompt.
struct TraceSectionRow: View {
    let section: PromptSection
    let isEdited: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    TraceOriginChip(label: originLabel, tone: .secondary)
                    Text(section.label)
                        .font(.callout)
                        .lineLimit(1)
                    if isEdited {
                        TraceOriginChip(label: "edited", tone: .warning)
                    }
                    Spacer(minLength: 4)
                    Text("\(section.body.count) chars")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(section.body)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nativPanelStyle(cornerRadius: .compact)
            }
        }
    }

    private var originLabel: String {
        switch section.origin {
        case .userSystemPrompt: "settings"
        case .project: "project"
        case .toolGuide: "tool guide"
        case .skill: "skill"
        case .opaque: "wire"
        default: section.origin.rawValue
        }
    }
}

/// One tool as it was advertised, with its schema behind a disclosure.
struct TraceToolDescriptorRow: View {
    let tool: ToolDescriptor
    let change: TraceToolChange

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(tool.name)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                    TraceOriginChip(label: originLabel, tone: .secondary)
                    switch change {
                    case .added: TraceOriginChip(label: "added", tone: .positive)
                    case .redefined: TraceOriginChip(label: "schema changed", tone: .warning)
                    case .unchanged: EmptyView()
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = tool.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let schema = tool.parameters, let text = try? schema.canonicalString() {
                        Text(text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativPanelStyle(cornerRadius: .compact)
            }
        }
    }

    private var originLabel: String {
        switch tool.origin {
        case .builtIn: "built in"
        case .custom: "custom"
        case .mcp: tool.originDetail.map { "mcp · \($0)" } ?? "mcp"
        default: tool.origin.rawValue
        }
    }
}

/// A message the call included, resolved back to its text.
struct TraceResolvedMessageRow: View {
    let message: ResolvedMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TraceOriginChip(label: message.reference.role.rawValue, tone: .secondary)
            if let text = message.text {
                Text(text)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(message.isVerified ? .primary : .secondary)
            } else {
                Text("content not retained")
                    .font(.callout.italic())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if message.text != nil, !message.isVerified {
                TraceOriginChip(label: "edited since", tone: .warning)
            }
        }
    }
}

struct TraceParameterGrid: View {
    let parameters: SamplingParameters

    var body: some View {
        let entries = entries
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(entries, id: \.0) { name, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var entries: [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ name: String, _ value: CustomStringConvertible?) {
            if let value { rows.append((name, String(describing: value))) }
        }
        add("temperature", parameters.temperature)
        add("top_p", parameters.topP)
        add("top_k", parameters.topK)
        add("min_p", parameters.minP)
        add("max tokens", parameters.maxTokens)
        add("repetition", parameters.repetitionPenalty)
        add("thinking", parameters.thinkingEnabled)
        add("thinking budget", parameters.thinkingBudget)
        add("tool choice", parameters.toolChoice)
        return rows
    }
}

struct TraceOriginChip: View {
    enum Tone {
        case secondary
        case positive
        case warning
        case negative
    }

    let label: String
    let tone: Tone

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .secondary: Color(nsColor: .secondaryLabelColor)
        case .positive: TracePalette.added
        case .warning: TracePalette.changed
        case .negative: TracePalette.removed
        }
    }
}

/// Compact "what changed" indicator shown on a collapsed call.
struct TraceDiffBadges: View {
    let diff: TraceExposureDiff

    var body: some View {
        HStack(spacing: 4) {
            if !diff.addedTools.isEmpty {
                TraceOriginChip(label: "+\(diff.addedTools.count)", tone: .positive)
            }
            if !diff.removedTools.isEmpty {
                TraceOriginChip(label: "−\(diff.removedTools.count)", tone: .negative)
            }
            if !diff.redefinedTools.isEmpty {
                TraceOriginChip(label: "~\(diff.redefinedTools.count)", tone: .warning)
            }
            if !diff.editedSections.isEmpty || !diff.addedSections.isEmpty {
                TraceOriginChip(label: "prompt changed", tone: .warning)
            }
        }
        .help("How this call's exposure differs from the previous one")
    }
}
