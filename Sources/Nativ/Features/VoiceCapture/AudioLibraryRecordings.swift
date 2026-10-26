import SwiftUI

struct AudioLibraryRecordings: View {
    let records: [AudioTranscriptionRecord]
    @ObservedObject var library: AudioCaptureLibrary
    let onOpen: (AudioTranscriptionRecord, AudioRecordingSection) -> Void
    let onRename: (AudioTranscriptionRecord, String) -> Void
    let onDelete: (AudioTranscriptionRecord) -> Void

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(records) { record in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        InlineEditableAudioTitle(title: record.displayTitle, placeholder: "Recording title",
                            font: .callout.weight(.semibold), onRename: { onRename(record, $0) })
                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if library.processingRecordIDs.contains(record.id) {
                            AudioRecordingProgress(recordID: record.id, library: library)
                        }
                    }
                    Spacer()
                    Button("Open recording") { onOpen(record, .summary) }
                    Button { library.togglePlayback(for: record) } label: {
                        Image(systemName: library.playingRecordID == record.id && !library.isPlaybackPaused
                              ? "pause.fill" : "play.fill")
                    }
                    .disabled(library.audioURL(for: record) == nil)
                    .accessibilityLabel("Play or pause recording")
                    AudioRecordingActions(record: record, library: library, onDelete: { onDelete(record) })
                }
                .padding(16)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            }
        }
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
