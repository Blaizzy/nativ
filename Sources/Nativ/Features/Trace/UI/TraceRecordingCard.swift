import NativTrace
import SwiftUI

/// Settings for what Nativ keeps about its own model calls.
///
/// States plainly that traces stay on the machine, because the honest reading of
/// "record what the model was shown" is "store my prompts", and a user deciding
/// whether to leave it on should not have to infer where that goes.
struct TraceRecordingCard: View {
    @Binding var settings: NativSettings

    @State private var storedBytes: Int64?
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.traceRecordingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record model traces")
                    Text("Keeps the system prompt, tools, and messages behind each model call so you can see exactly what it was shown. Traces never leave this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.traceRecordingEnabled {
                Divider()

                HStack(spacing: 20) {
                    retentionField(
                        title: "Keep for",
                        value: $settings.traceRetentionDays,
                        unit: "days",
                        unlimitedLabel: "forever"
                    )
                    retentionField(
                        title: "Keep at most",
                        value: $settings.traceMaximumTraces,
                        unit: "traces",
                        unlimitedLabel: "unlimited"
                    )
                }
            }

            Divider()

            HStack {
                Text(storedBytes.map { "Using \(NativFormatting.gigabytes(fromBytes: $0))" } ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isClearing ? "Deleting…" : "Delete recorded traces") {
                    clear()
                }
                .disabled(isClearing)
            }
        }
        .padding(16)
        .nativPanelStyle(cornerRadius: .large)
        .task { await refreshSize() }
    }

    private func retentionField(
        title: String,
        value: Binding<Int>,
        unit: String,
        unlimitedLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                Text(value.wrappedValue == 0 ? unlimitedLabel : unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func clear() {
        isClearing = true
        Task {
            defer { isClearing = false }
            guard let store = TraceServices.shared.readableStore() else { return }
            try? await store.deleteAll()
            await refreshSize()
        }
    }

    /// Sums the database and its write-ahead sidecars. Reporting only the main
    /// file understates usage right after recording, when most of what was
    /// written is still in the WAL.
    private func refreshSize() async {
        let base = TraceStore.defaultURL()
        let paths = [base.path, base.path + "-wal", base.path + "-shm"]
        storedBytes = paths.reduce(into: Int64(0)) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}
