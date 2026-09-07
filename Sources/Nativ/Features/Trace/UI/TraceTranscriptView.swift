import NativTrace
import SwiftUI

/// Renders folded trace blocks in reading order.
///
/// Dispatches on `TraceItem.Body`, which is exhaustive — including the
/// `.unknown` case, so an event written by a newer build still occupies a row
/// rather than making the transcript quietly shorter than the trace.
struct TraceTranscriptView: View {
    @ObservedObject var model: TraceInspectorViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let instance = model.selectedInstance, !instance.inheritedContext.isEmpty {
                        TraceInheritedContextRow(
                            messages: instance.inheritedContext,
                            fromModelID: instance.precedingModelID
                        )
                    }

                    ForEach(model.blocks) { block in
                        switch block {
                        case .boundary(let boundary):
                            TraceBoundaryRow(boundary: boundary)
                        case .loose(let item):
                            row(for: item)
                        case .turn(let turn):
                            turnView(turn)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.selectedCallID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: TraceTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompt = turn.prompt {
                row(for: prompt)
            }
            ForEach(turn.segments) { item in
                row(for: item)
            }
        }
    }

    @ViewBuilder
    private func row(for item: TraceItem) -> some View {
        switch item.body {
        case .message(let message):
            TraceMessageRow(message: message, timestamp: item.timestamp)
                .id(item.id)
        case .exposure:
            // Falling through to nothing here would drop a row from the
            // transcript, which is the one thing the fold guarantees never
            // happens. Resolution failing is a bug worth seeing, not hiding.
            if let exposure = model.exposure(for: item.id) {
                TraceExposureCard(
                    exposure: exposure,
                    diff: model.diff(for: item.id),
                    label: model.callLabel(for: item.id),
                    modelID: item.scope.modelID,
                    isHighlighted: model.selectedCallID == item.id
                )
                .id(item.id)
            } else {
                TraceLifecycleRow(
                    lifecycle: TraceLifecycleBody(
                        kind: .failure,
                        title: model.callLabel(for: item.id),
                        detail: "exposure could not be resolved"
                    ),
                    timestamp: item.timestamp
                )
                .id(item.id)
            }
        case .tool(let tool):
            TraceToolRow(tool: tool).id(item.id)
        case .lifecycle(let lifecycle):
            TraceLifecycleRow(lifecycle: lifecycle, timestamp: item.timestamp).id(item.id)
        case .unknown(let kind, let payload):
            TraceUnknownRow(kind: kind, payload: payload).id(item.id)
        }
    }
}

struct TraceMessageRow: View {
    let message: TraceMessageBody
    let timestamp: Date

    @State private var isThinkingExpanded = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                thinking(reasoning)
            }

            HStack {
                if message.role == .user { Spacer(minLength: 40) }
                Text(message.text.isEmpty && message.isStreaming ? "…" : message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        if message.role == .user {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(TracePalette.stroke, lineWidth: 0.5)
                        }
                    }
                if message.role != .user { Spacer(minLength: 40) }
            }

            HStack(spacing: 8) {
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                if let usage = message.usage, let prompt = usage.promptTokens {
                    Text("\(prompt) in · \(usage.completionTokens ?? 0) out")
                }
                if let reason = message.finishReason {
                    Text(Self.finishReasonLabel(reason))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// The wire value is API vocabulary; the transcript is prose.
    static func finishReasonLabel(_ reason: String) -> String {
        switch reason {
        case "stop": "finished"
        case "tool_calls": "called tools"
        case "length": "hit the token limit"
        case "content_filter": "stopped by content filter"
        default: reason
        }
    }

    private func thinking(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isThinkingExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isThinkingExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isThinkingExpanded {
                Text(reasoning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .nativPanelStyle(cornerRadius: .compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The conversation a model was handed when it took over a chat.
///
/// Collapsed, because it is context rather than activity — but present, because
/// a trace that opens with an answer to an unseen question is not an account of
/// what the model saw.
struct TraceInheritedContextRow: View {
    let messages: [ResolvedMessage]
    let fromModelID: String?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.callout)
                    Text("\(messages.count) messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { message in
                        TraceResolvedMessageRow(message: message)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativPanelStyle(cornerRadius: .compact)
    }

    private var title: String {
        guard let fromModelID else { return "Context carried into this model" }
        return "Carried over from \(fromModelID)"
    }
}

struct TraceBoundaryRow: View {
    let boundary: TraceBoundary

    var body: some View {
        HStack(spacing: 8) {
            line
            label
            line
        }
        .padding(.vertical, 6)
    }

    /// Every text here is single-line on purpose. The rules either side are
    /// flexible, so without a line limit they compress the label until it wraps
    /// one character per line — which is what this panel did at its default
    /// width. A long model id truncates in the middle instead of pushing the
    /// rules off the row.
    private var label: some View {
        HStack(spacing: 6) {
            Image(
                systemName: boundary.kind == .modelSwitched
                    ? "arrow.triangle.swap"
                    : "dot.radiowaves.left.and.right"
            )
            .font(.caption)

            Text(boundary.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let detail = boundary.detail {
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(boundary.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .layoutPriority(1)
    }

    private var line: some View {
        Rectangle()
            .fill(TracePalette.stroke)
            .frame(height: 1)
    }
}

struct TraceLifecycleRow: View {
    let lifecycle: TraceLifecycleBody
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lifecycle.kind == .failure ? "exclamationmark.triangle" : "flag")
                .font(.caption)
                .foregroundStyle(lifecycle.kind == .failure ? TracePalette.removed : .secondary)
            Text(lifecycle.title).font(.callout).lineLimit(1)
            if let detail = lifecycle.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct TraceUnknownRow: View {
    let kind: TraceEventKind
    let payload: TraceJSON

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TraceOriginChip(label: "unrecognised", tone: .warning)
                Text(kind.rawValue).font(.callout.monospaced())
            }
            if let text = try? payload.canonicalString() {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nativPanelStyle(cornerRadius: .compact)
    }
}
