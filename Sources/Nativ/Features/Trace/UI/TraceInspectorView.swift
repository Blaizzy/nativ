import SwiftUI

struct TraceInspectorView: View {
    enum Source: Hashable {
        case session(UUID)
    }

    private struct Reload: Hashable {
        let source: Source
        let token: AnyHashable?
    }

    let source: Source
    var reloadToken: AnyHashable?
    let onOpenArtifact: (UUID) -> Void

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
        } else {
            TraceTranscriptView(model: model, onOpenArtifact: onOpenArtifact)
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
        var parts = ["\(model.eventCount) events", "\(calls) \(calls == 1 ? "model call" : "model calls")"]
        if let label = model.selectedInstance?.modelLabel {
            parts.insert(label, at: 0)
        }
        return parts.joined(separator: " · ")
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
        }
    }
}
