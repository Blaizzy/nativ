import SwiftUI

struct ChatAudioSessionPicker: View {
    @ObservedObject var analytics: AudioAnalyticsStore
    let onAttach: ([AudioTranscriptionRecord]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if analytics.captureRecords.isEmpty {
                ContentUnavailableView {
                    Label("No saved recordings", systemImage: "waveform.badge.plus")
                } description: {
                    Text("Recordings and meetings you save appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(analytics.captureRecords, selection: $selection) { record in
                    ChatAudioSessionRow(record: record)
                        .tag(record.id)
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add a Recording")
                .font(.headline)
            Text("Attach a recording's transcript so you can talk about it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Attach") {
                let selected = analytics.captureRecords.filter { selection.contains($0.id) }
                onAttach(selected)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

private struct ChatAudioSessionRow: View {
    let record: AudioTranscriptionRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.resolvedKind.systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [record.recordedAt.formatted(date: .abbreviated, time: .shortened)]
        if record.summary?.isEmpty == false {
            parts.append("Summary")
        }
        parts.append("\(record.wordCount) words")
        return parts.joined(separator: " · ")
    }
}
