import NativTrace
import SwiftUI

/// One tool call and its outcome, collapsed into a single row.
struct TraceToolRow: View {
    let tool: TraceToolBody

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    Text(tool.name)
                        .font(.callout.monospaced())
                    if let detail = tool.originDetail {
                        TraceOriginChip(label: detail, tone: .secondary)
                    }
                    if let decision = tool.consentDecision {
                        TraceOriginChip(
                            label: decision,
                            tone: decision == "denied" ? .negative : .secondary
                        )
                    }
                    Spacer(minLength: 4)
                    if let duration = tool.durationMilliseconds {
                        Text("\(duration) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let arguments = tool.arguments, let text = try? arguments.canonicalString() {
                        labelled("Arguments", text)
                    }
                    if let output = tool.output, !output.isEmpty {
                        labelled("Result", output)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .nativPanelStyle(cornerRadius: .compact)
    }

    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(body)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusSymbol: String {
        switch tool.status {
        case .awaitingConsent: "hand.raised"
        case .running: "circle.dashed"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .denied: "nosign"
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .completed: TracePalette.added
        case .failed, .denied: TracePalette.removed
        case .awaitingConsent: TracePalette.changed
        case .running: Color.secondary
        }
    }
}
