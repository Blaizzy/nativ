import SwiftUI

/// Saved recordings with a summary preview and separate playback controls.
struct AudioLibraryRecordings: View {
    let records: [AudioTranscriptionRecord]
    let profiles: [AudioSpeakerProfile]
    @ObservedObject var library: AudioCaptureLibrary
    let onOpen: (AudioTranscriptionRecord, AudioRecordingSection) -> Void
    let onRename: (AudioTranscriptionRecord, String) -> Void
    let onDelete: (AudioTranscriptionRecord) -> Void

    @State private var renamingRecord: AudioTranscriptionRecord?
    @State private var editedTitle = ""
    @State private var hoveredID: String?

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(records) { record in
                if record.resolvedKind == .dictation {
                    AudioTranscriptRow(record: record, onDelete: { onDelete(record) })
                } else {
                    summaryCard(record)
                }
            }
        }
        .alert("Rename recording", isPresented: Binding(
            get: { renamingRecord != nil }, set: { if !$0 { renamingRecord = nil } }
        )) {
            TextField("Recording title", text: $editedTitle)
            Button("Cancel", role: .cancel) { renamingRecord = nil }
            Button("Save") {
                if let record = renamingRecord { onRename(record, editedTitle) }
                renamingRecord = nil
            }
            .disabled(editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func summaryCard(_ record: AudioTranscriptionRecord) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Button { onOpen(record, .summary) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    recordHeading(record)
                    Text(excerpt(record)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    people(record)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open summary for \(record.displayTitle)")
            .accessibilityIdentifier("audio.library.open.\(record.id)")
            VStack(alignment: .trailing, spacing: 22) {
                controls(record)
                Button { onOpen(record, .summary) } label: {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).accessibilityLabel("Open recording")
            }
            .padding(16)
        }
        .background(Color.primary.opacity(hoveredID == record.id ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(hoveredID == record.id ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .onHover { hoveredID = $0 ? record.id : nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio.library.record.\(record.id)")
    }

    private func recordHeading(_ record: AudioTranscriptionRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.displayTitle).font(.callout.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = record.durationSeconds {
                    Text("·")
                    Text(NativFormatting.clockDuration(duration)).monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if library.processingRecordIDs.contains(record.id) {
                AudioRecordingProgress(recordID: record.id, library: library)
            }
        }
    }

    private func people(_ record: AudioTranscriptionRecord) -> some View {
        let names = speakerNames(record)
        return HStack(spacing: 6) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                HStack(spacing: 5) {
                    Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 23, height: 23)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                    Text(name).font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            if names.count > 3 { Text("+\(names.count - 3)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func controls(_ record: AudioTranscriptionRecord) -> some View {
        let playing = library.playingRecordID == record.id && !library.isPlaybackPaused
        return HStack(spacing: 8) {
            Button { library.togglePlayback(for: record) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.045), in: Circle())
                    .overlay { Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain).disabled(library.audioURL(for: record) == nil)
            .accessibilityLabel("\(playing ? "Pause" : "Play") \(record.displayTitle)")
            .accessibilityIdentifier("audio.library.play.\(record.id)")
            AudioRecordingActions(record: record, library: library, onDelete: { onDelete(record) }, onRename: {
                editedTitle = record.displayTitle
                renamingRecord = record
            })
        }
    }

    private func speakerNames(_ record: AudioTranscriptionRecord) -> [String] {
        guard let diarization = record.diarization?.groupedByProfile else { return [] }
        return diarization.speakerIDs.map { speaker in
            let profileID = diarization.speakerProfileIDs?[String(speaker)]
            return profiles.first { $0.id == profileID }?.name ?? diarization.speakerName(speaker)
        }
    }

    private func excerpt(_ record: AudioTranscriptionRecord) -> AttributedString {
        guard let summary = record.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AttributedString("No summary yet. Open the recording to generate one.")
        }
        let text = summary.split(separator: "\n").prefix(8).map {
            String($0).replacingOccurrences(of: #"^\s*(?:#{1,6}\s+|[-*+]\s+)"#,
                                           with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }.joined(separator: " · ")
        let parsed = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let plainText = String(parsed.characters)
        return AttributedString(String(plainText.prefix(320)) + (plainText.count > 320 ? "…" : ""))
    }
}

struct AudioLibraryControls: View {
    @Binding var filter: AudioLibraryFilter
    let profiles: [AudioSpeakerProfile]
    var showsKind = true
    var defaultStatus: AudioLibraryFilter.Status = .all
    var identifier = "audio.library"

    private var speakerTitle: String {
        if filter.speakerID == AudioLibraryFilter.unlinkedSpeakerID { return "Unlinked speakers" }
        return profiles.first { $0.id == filter.speakerID }?.name ?? "All speakers"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search recordings, transcripts, summaries or speakers", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("\(identifier).search")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filterMenus }
                VStack(alignment: .leading, spacing: 10) { filterMenus }
            }
        }
    }

    @ViewBuilder private var filterMenus: some View {
        if showsKind {
            Picker("Type", selection: $filter.kind) {
                ForEach(AudioLibraryFilter.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("\(identifier).kind")
        }
        Picker("Date", selection: $filter.period) {
            ForEach(AudioLibraryFilter.Period.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
        .accessibilityIdentifier("\(identifier).period")
        Picker("Status", selection: $filter.status) {
            ForEach(AudioLibraryFilter.Status.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
        .accessibilityIdentifier("\(identifier).status")
        Menu {
            Button("All speakers") { filter.speakerID = "" }
            Button("Unlinked speakers") { filter.speakerID = AudioLibraryFilter.unlinkedSpeakerID }
            Divider()
            ForEach(profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { profile in
                Button { filter.speakerID = profile.id } label: {
                    if filter.speakerID == profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name) }
                }
            }
        } label: {
            Label(speakerTitle, systemImage: "person.2").lineLimit(1)
        }
        .frame(maxWidth: 210, alignment: .leading).fixedSize()
        .accessibilityIdentifier("\(identifier).speaker")
        Button("Clear filters") {
            filter = AudioLibraryFilter(kind: showsKind ? .recordings : .meetings, status: defaultStatus)
        }
        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("\(identifier).clear-filters")
    }
}

struct AudioLibraryPagination: View {
    let page: AudioLibraryPage
    @Binding var selection: Int
    var identifier = "audio.library"

    var body: some View {
        HStack(spacing: 12) {
            Text("\(page.first)–\(page.last) of \(page.total)")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Recordings \(page.first) through \(page.last) of \(page.total)")
                .accessibilityIdentifier("\(identifier).range")
            Spacer(minLength: 8)
            Text("Page \(page.index + 1) of \(page.count)")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifier).page")
            Button { selection = max(0, page.index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(page.index == 0).accessibilityLabel("Previous page")
                .accessibilityIdentifier("\(identifier).previous-page")
            Button { selection = min(page.count - 1, page.index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(page.index >= page.count - 1).accessibilityLabel("Next page")
                .accessibilityIdentifier("\(identifier).next-page")
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct AudioSpeakerRecordingPicker: View {
    @ObservedObject var store: AudioAnalyticsStore
    @ObservedObject var library: AudioCaptureLibrary
    let onProcess: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = AudioLibraryFilter(kind: .meetings, status: .needsProcessing)
    @State private var selectedIDs = Set<String>()
    @State private var pageIndex = 0

    private func isAvailable(_ record: AudioTranscriptionRecord) -> Bool {
        library.audioURL(for: record) != nil && !library.processingRecordIDs.contains(record.id)
            && !library.speakerRecognition.processingRecordIDs.contains(record.id)
    }

    var body: some View {
        let matches = filter.records(in: store.records, profiles: store.speakerProfiles)
        let page = AudioLibraryPage(records: matches, index: pageIndex)
        let available = Set(store.records.filter { $0.resolvedKind == .meeting && isAvailable($0) }.map(\.id))
        let selectable = Set(matches.map(\.id)).intersection(available)
        let selected = selectedIDs.intersection(selectable)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Process recordings").font(.title2.weight(.semibold))
                Text("Meetings with completed transcripts and existing speaker links are hidden by default. Use Review for remaining unlinked speakers, or Any status to revisit a meeting.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("New meetings are processed automatically after transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AudioLibraryControls(filter: $filter, profiles: store.speakerProfiles,
                                 showsKind: false, defaultStatus: .needsProcessing, identifier: "speaker-processing")
            HStack {
                Button("Select all \(selectable.count) \(selectable.count == 1 ? "result" : "results")") {
                    selectedIDs.formUnion(selectable)
                }
                .disabled(selectable.isEmpty).accessibilityIdentifier("speaker-processing.select-all")
                Button("Clear selection") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
                Spacer()
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(page.records) { record in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(record.id) },
                            set: { if $0 { selectedIDs.insert(record.id) } else { selectedIDs.remove(record.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.displayTitle).font(.callout.weight(.medium)).lineLimit(2)
                                HStack {
                                    Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                    if let duration = record.durationSeconds {
                                        Text("· \(AudioDiarization.timestamp(duration))")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                if !isAvailable(record) {
                                    Text(library.audioURL(for: record) == nil ? "Audio file unavailable" : "Currently processing")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if record.diarization?.hasCompletedTranscription != true {
                                    Text("Needs diarization and transcription first").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    let linked = record.diarization?.speakerIDs.filter {
                                        guard let profileID = record.diarization?.speakerProfileIDs?[String($0)] else { return false }
                                        return store.speakerProfiles.contains { $0.id == profileID }
                                    }.count ?? 0
                                    Text(linked == 0 ? "No linked speaker profiles" : "\(linked) of \(record.diarization?.speakerIDs.count ?? 0) speakers linked")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.checkbox).disabled(!available.contains(record.id))
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("speaker-processing.record.\(record.id)")
                    }
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: filter.query).frame(maxWidth: .infinity)
                    }
                }
            }
            AudioLibraryPagination(page: page, selection: $pageIndex, identifier: "speaker-processing")
            Divider()
            HStack {
                Text("Original audio files are kept.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Process \(selected.count) \(selected.count == 1 ? "recording" : "recordings")") {
                    onProcess(selected)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || library.isBusy)
                .accessibilityIdentifier("speaker-processing.start")
            }
        }
        .padding(24).frame(width: 740, height: 660)
        .onChange(of: filter) { _, _ in pageIndex = 0 }
    }
}
