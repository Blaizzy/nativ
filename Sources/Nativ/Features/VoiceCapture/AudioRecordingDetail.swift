import SwiftUI

enum AudioRecordingSection: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"

    var systemImage: String { self == .summary ? "sparkles" : "text.alignleft" }
}

struct AudioRecordingDetail: View {
    let record: AudioTranscriptionRecord
    @ObservedObject var library: AudioCaptureLibrary
    @ObservedObject var analytics: AudioAnalyticsStore
    @ObservedObject var recognition: AudioSpeakerRecognition
    let onBack: () -> Void
    let onRename: (String) -> Void
    let onRenameSpeaker: (Int, String) -> Void
    let onDelete: () -> Void
    let onOpenSpeakerProfile: (String) -> Void
    private let returnsToSpeakerProfile: Bool

    @State private var section: AudioRecordingSection
    @State private var showsSpeakers = false
    @State private var copiedSection: AudioRecordingSection?
    @State private var seekTarget: Double?
    @State private var seekRequestID: UUID?
    @State private var speakerFilter: AudioTranscriptSpeakerFilter

    init(
        record: AudioTranscriptionRecord,
        library: AudioCaptureLibrary,
        analytics: AudioAnalyticsStore,
        recognition: AudioSpeakerRecognition,
        initialSection: AudioRecordingSection = .summary,
        initialSpeakerProfileID: String? = nil,
        initialShowsSpeakers: Bool = false,
        onBack: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onRenameSpeaker: @escaping (Int, String) -> Void,
        onDelete: @escaping () -> Void,
        onOpenSpeakerProfile: @escaping (String) -> Void = { _ in }
    ) {
        self.record = record
        self.library = library
        self.analytics = analytics
        self.recognition = recognition
        self.onBack = onBack
        self.onRename = onRename
        self.onRenameSpeaker = onRenameSpeaker
        self.onDelete = onDelete
        self.onOpenSpeakerProfile = onOpenSpeakerProfile
        returnsToSpeakerProfile = initialSpeakerProfileID != nil
        _section = State(initialValue: initialSpeakerProfileID == nil ? initialSection : .transcript)
        _showsSpeakers = State(initialValue: initialShowsSpeakers)
        _speakerFilter = State(initialValue: initialSpeakerProfileID.map(AudioTranscriptSpeakerFilter.profile) ?? .all)
    }

    private var isProcessing: Bool { library.processingRecordIDs.contains(record.id) }
    private var summary: String? {
        guard let summary = record.summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onBack) {
                Label(returnsToSpeakerProfile ? "Speaker profile" : "Audio Library", systemImage: "chevron.left")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recording.back")

            header

            VStack(spacing: 0) {
                toolbar
                Divider()
                if isProcessing {
                    HStack {
                        AudioRecordingProgress(recordID: record.id, library: library)
                        Spacer()
                        Text("You can keep reading while this finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    Divider()
                }
                recordingContent
                Divider()
                AudioRecordingTransport(record: record, library: library, playback: library.playback)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
        }
        .padding(24)
        .frame(maxWidth: 1_500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: copiedSection) {
            guard copiedSection != nil else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copiedSection = nil
        }
    }

    private var recordingContent: some View {
        GeometryReader { geometry in
            if showsSpeakers && geometry.size.width < 850 {
                VStack(spacing: 0) {
                    readingPane
                    Divider()
                    speakersPanel
                        .frame(height: min(340, geometry.size.height * 0.48))
                }
            } else {
                HStack(spacing: 0) {
                    readingPane
                    if showsSpeakers {
                        Divider()
                        speakersPanel.frame(width: 310)
                    }
                }
            }
        }
    }

    // Both panes retain their reading position and search when switching tabs.
    private var readingPane: some View {
        ZStack {
            summaryPane
                .opacity(section == .summary ? 1 : 0)
                .disabled(section != .summary)
                .allowsHitTesting(section == .summary)
                .accessibilityHidden(section != .summary)
            transcriptPane
                .opacity(section == .transcript ? 1 : 0)
                .disabled(section != .transcript)
                .allowsHitTesting(section == .transcript)
                .accessibilityHidden(section != .transcript)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var speakersPanel: some View {
        AudioRecordingSpeakersPanel(
            record: record, analytics: analytics, library: library, recognition: recognition,
            onClose: { showsSpeakers = false },
            onRenameSpeaker: onRenameSpeaker,
            onOpenProfile: onOpenSpeakerProfile,
            onViewTranscript: { speaker in
                if let profileID = analytics.profileID(speakerID: speaker, recordID: record.id) {
                    speakerFilter = .profile(profileID)
                } else {
                    speakerFilter = .speaker(speaker)
                }
                section = .transcript
            }
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                InlineEditableAudioTitle(
                    title: record.displayTitle, placeholder: "Recording title",
                    font: .title3.weight(.semibold), onRename: onRename
                )
                Text(metadata)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            AudioRecordingActions(record: record, library: library, onDelete: onDelete)
        }
    }

    private var metadata: String {
        var parts = [record.recordedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.durationSeconds { parts.append(NativFormatting.clockDuration(duration)) }
        if !record.transcript.isEmpty { parts.append("\(record.wordCount.formatted()) words") }
        if let modelID = record.modelID { parts.append(audioTranscriptionModelDisplayName(modelID)) }
        return parts.joined(separator: " · ")
    }

    private var toolbar: some View {
        HStack(spacing: 18) {
            ForEach(AudioRecordingSection.allCases, id: \.self) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 6) {
                        Label(item.rawValue, systemImage: item.systemImage)
                        if item == .transcript {
                            Text(record.wordCount.formatted()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.weight(section == item ? .semibold : .regular))
                    .foregroundStyle(section == item ? Color.accentColor : Color.secondary)
                    .padding(.vertical, 15)
                    .overlay(alignment: .bottom) {
                        if section == item { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(section == item ? .isSelected : [])
                .accessibilityIdentifier("recording.tab.\(item == .summary ? "summary" : "transcript")")
            }
            Spacer(minLength: 8)
            Button(action: copyCurrentSection) {
                Image(systemName: copiedSection == section ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(copiedSection == section ? "Copied" : "Copy \(section.rawValue.lowercased())")
            .accessibilityLabel("Copy \(section.rawValue.lowercased())")
            .disabled(section == .summary ? summary == nil : record.transcript.isEmpty)
            if record.diarization?.speakerIDs.isEmpty == false {
                Button { showsSpeakers.toggle() } label: {
                    Label("Speakers", systemImage: "person.2")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(showsSpeakers ? Color.accentColor : nil)
                .accessibilityIdentifier("recording.speakers")
                .accessibilityAddTraits(showsSpeakers ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var summaryPane: some View {
        if let summary {
            AudioSummaryView(
                document: AudioSummaryDocument(record: record, summary: summary),
                legacyReferences: summary.contains("nativ://recording/") ? [] : AudioSummaryReference.references(
                    in: summary, duration: record.durationSeconds ?? 0
                ),
                onOpenLegacy: { seconds in
                    seekTarget = seconds
                    seekRequestID = UUID()
                    speakerFilter = .all
                    section = .transcript
                    if library.audioURL(for: record) != nil { library.seekPlayback(for: record, to: seconds) }
                },
                onOpenLink: openSummaryReference
            )
            .accessibilityIdentifier("recording.summary")
        } else {
            emptyState(isSummary: true)
        }
    }

    private func openSummaryReference(_ url: URL) -> Bool {
        guard url.scheme == "nativ" else { return false }
        guard let target = AudioSummarySources(record: record).target(for: url) else { return true }
        switch target {
        case .speaker(let id):
            seekTarget = nil
            seekRequestID = UUID()
            speakerFilter = analytics.profileID(speakerID: id, recordID: record.id)
                .map(AudioTranscriptSpeakerFilter.profile) ?? .speaker(id)
            section = .transcript
        case .passage(let seconds):
            speakerFilter = .all
            seekTarget = seconds
            seekRequestID = UUID()
            section = .transcript
            if library.audioURL(for: record) != nil { library.seekPlayback(for: record, to: seconds) }
        }
        return true
    }

    @ViewBuilder private var transcriptPane: some View {
        if record.transcript.isEmpty {
            emptyState(isSummary: false)
        } else {
            AudioTranscriptDetail(
                record: record, audioURL: library.audioURL(for: record), playback: library.playback,
                onSeek: { library.seekPlayback(for: record, to: $0) },
                onRenameSpeaker: onRenameSpeaker, seekTarget: seekTarget,
                seekRequestID: seekRequestID, isVisible: section == .transcript,
                speakerFilter: $speakerFilter
            )
            .padding(20)
            .accessibilityIdentifier("recording.transcript")
        }
    }

    private func emptyState(isSummary: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: isSummary ? "sparkles" : "text.alignleft")
                .font(.system(size: 28)).foregroundStyle(Color.accentColor)
            Text(isProcessing ? "Your recording is being prepared" : (isSummary ? "Summarize this recording" : "Transcribe this recording"))
                .font(.title3.weight(.semibold))
            Text(record.transcript.isEmpty
                 ? "Create a transcript to turn this recording into searchable text and a summary."
                 : "Get an overview, key points, and action items. The full transcript is available in the Transcript tab.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            if !isProcessing {
                Button(record.transcript.isEmpty ? "Generate transcript" : "Generate summary") {
                    if record.transcript.isEmpty { library.retryTranscription(record) }
                    else { library.summarize(record) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(record.transcript.isEmpty && library.audioURL(for: record) == nil)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyCurrentSection() {
        guard let text = section == .summary ? summary : record.displayTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSection = section
    }
}

private struct AudioRecordingTransport: View {
    let record: AudioTranscriptionRecord
    @ObservedObject var library: AudioCaptureLibrary
    @ObservedObject var playback: AudioPlaybackState

    private var isCurrent: Bool { playback.recordID == record.id }
    private var position: Double { isCurrent ? playback.position : 0 }
    private var duration: Double { isCurrent ? playback.duration : record.durationSeconds ?? 0 }
    private var isPlaying: Bool { isCurrent && !library.isPlaybackPaused }

    var body: some View {
        HStack(spacing: 18) {
            Button { library.seekPlayback(for: record, to: max(0, position - 10)) } label: {
                Image(systemName: "gobackward.10")
            }
            .accessibilityLabel("Back 10 seconds")
            Button { library.togglePlayback(for: record) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(.white).frame(width: 34, height: 34)
                    .background(Color.accentColor, in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause recording" : "Play recording")
            Button { library.seekPlayback(for: record, to: min(duration, position + 10)) } label: {
                Image(systemName: "goforward.10")
            }
            .accessibilityLabel("Forward 10 seconds")
            Text("\(AudioDiarization.timestamp(position)) / \(AudioDiarization.timestamp(duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Picker("Playback speed", selection: Binding(
                get: { playback.rate }, set: { library.setPlaybackRate($0) }
            )) {
                Text("1×").tag(Float(1))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
                Text("2×").tag(Float(2))
            }
            .labelsHidden().frame(width: 72)
            .accessibilityLabel("Playback speed")
        }
        .buttonStyle(.plain)
        .disabled(library.audioURL(for: record) == nil)
        .padding(.horizontal, 24).padding(.vertical, 15)
    }
}

struct AudioRecordingProgress: View {
    let recordID: String
    @ObservedObject var library: AudioCaptureLibrary

    var body: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(library.diarizingRecordIDs.contains(recordID) ? "Identifying speakers"
                 : library.transcribingRecordIDs.contains(recordID) ? "Transcribing" : "Creating summary")
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Shared recording actions for the library card and its full detail view.
struct AudioRecordingActions: View {
    let record: AudioTranscriptionRecord
    @ObservedObject var library: AudioCaptureLibrary
    let onDelete: () -> Void
    var onRename: (() -> Void)? = nil
    @State private var isExporting = false
    @State private var exportedFormat: AudioRecordExportFormat?
    @State private var exportError: String?

    private var isProcessing: Bool { library.processingRecordIDs.contains(record.id) }
    private var hasAudio: Bool { library.audioURL(for: record) != nil }

    var body: some View {
        HStack(spacing: 8) {
            if isExporting {
                ProgressView().controlSize(.small)
            } else if let exportedFormat {
                Label("\(exportedFormat.title) exported", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Menu {
                if let onRename {
                    Button("Rename recording", systemImage: "pencil", action: onRename)
                    Divider()
                }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    ForEach(AudioRecordExportFormat.allCases, id: \.self) { format in
                        Button(format.title) { export(as: format) }
                    }
                }
                .disabled(isExporting || !AudioRecordExport(record: record).isAvailable)
                Divider()
                Menu("Regenerate", systemImage: "arrow.clockwise") {
                    Button("Transcript") { library.retryTranscription(record) }
                        .disabled(!hasAudio || isProcessing)
                    Button("Summary") { library.summarize(record) }
                        .disabled(record.transcript.isEmpty || isProcessing)
                }
                Button("Copy Transcript") { copy(record.displayTranscript) }
                    .disabled(record.transcript.isEmpty)
                if let summary = record.summary, !summary.isEmpty {
                    Button("Copy Summary") { copy(summary) }
                }
                Divider()
                Button("Reveal in Finder") { library.revealAudio(for: record) }
                    .disabled(!hasAudio)
                Button("Delete Recording", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Recording actions")
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The document could not be saved.")
        }
        .task(id: exportedFormat) {
            guard exportedFormat != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            exportedFormat = nil
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(as format: AudioRecordExportFormat) {
        let document = AudioRecordExport(record: record)
        guard document.isAvailable, !isExporting else { return }
        exportedFormat = nil
        let panel = NSSavePanel()
        panel.title = "Export Summary and Transcript"
        panel.prompt = "Export"
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = document.filename(for: format)
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExporting = true
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try document.write(to: url, format: format)
                    }.value
                    isExporting = false
                    exportedFormat = format
                } catch {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }
}
