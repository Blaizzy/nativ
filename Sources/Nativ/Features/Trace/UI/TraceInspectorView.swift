import NativTrace
import SwiftUI

extension Notification.Name {
    /// Posted by the View menu to show or hide the trace inspector in chat.
    static let toggleTraceInspector = Notification.Name("ToggleTraceInspector")
}

/// What the model was shown, for one chat session or one request.
///
/// Two panes: the calls in the trace, and the transcript. Selecting a call
/// scrolls its exposure into view rather than swapping the content, so the call
/// stays in the context of the conversation it belongs to — which is the whole
/// point of reading a trace rather than a log line.
struct TraceInspectorView: View {
    enum Source: Hashable {
        case session(UUID)
        case request(String)
    }

    private struct Reload: Hashable {
        let source: Source
        let token: AnyHashable?
    }

    let source: Source
    var showsCallSidebar = true
    /// Changes when the producer may have written more events — the end of a
    /// turn, not every token. Reloading per token would re-read the database
    /// hundreds of times for one answer.
    var reloadToken: AnyHashable?

    @StateObject private var model = TraceInspectorViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: Reload(source: source, token: reloadToken)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.loadFailure {
            unavailable(
                "Trace unavailable",
                systemImage: "exclamationmark.triangle",
                message: failure
            )
        } else if model.isLoading && model.blocks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isEmpty {
            unavailable(
                "No trace recorded",
                systemImage: "text.magnifyingglass",
                message: "Nothing has been recorded here yet. Recording can be turned off in Settings."
            )
        } else if showsCallSidebar && !model.calls.isEmpty {
            HSplitView {
                TraceCallSidebar(model: model)
                    .frame(minWidth: 190, idealWidth: 230, maxWidth: 320)
                TraceTranscriptView(model: model)
                    .frame(minWidth: 420)
            }
        } else {
            TraceTranscriptView(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Model trace")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload this trace")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let calls = model.calls.count
        return "\(model.eventCount) events · \(calls) \(calls == 1 ? "model call" : "model calls")"
    }

    private func unavailable(
        _ title: String,
        systemImage: String,
        message: String
    ) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        switch source {
        case .session(let id): await model.loadSession(id)
        case .request(let id): await model.loadRequest(id)
        }
    }
}

/// The calls in a trace, newest last, with what changed between them.
struct TraceCallSidebar: View {
    @ObservedObject var model: TraceInspectorViewModel

    var body: some View {
        List(model.calls, selection: $model.selectedCallID) { call in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(call.title).font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Text(call.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(call.advertisesTools
                    ? "\(call.toolCount) \(call.toolCount == 1 ? "tool" : "tools")"
                    : "no tools offered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !call.diff.isEmpty {
                    TraceDiffBadges(diff: call.diff)
                }
            }
            .padding(.vertical, 3)
        }
        .listStyle(.sidebar)
    }
}
