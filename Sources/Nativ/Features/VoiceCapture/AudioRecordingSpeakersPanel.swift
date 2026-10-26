import SwiftUI

/// A recording's numbered voices link to persistent people and can be corrected.
/// Correcting a link here never changes that person's other recordings.
struct AudioRecordingSpeakersPanel: View {
    let record: AudioTranscriptionRecord
    @ObservedObject var analytics: AudioAnalyticsStore
    @ObservedObject var library: AudioCaptureLibrary
    @ObservedObject var recognition: AudioSpeakerRecognition
    let onClose: () -> Void
    let onRenameSpeaker: (Int, String) -> Void
    let onOpenProfile: (String) -> Void
    let onViewTranscript: (Int) -> Void

    @State private var editor: SpeakerEditor?
    @State private var operationError: String?
    @State private var lastLinkUndo: AudioSpeakerReviewUndo?

    private struct SpeakerEditor: Identifiable {
        let speakerID: Int
        let isLabelOnly: Bool
        var id: String { "\(speakerID)-\(isLabelOnly)" }
    }

    private var currentRecord: AudioTranscriptionRecord {
        analytics.records.first { $0.id == record.id } ?? record
    }
    private var speakerIDs: [Int] { currentRecord.diarization?.speakerIDs ?? [] }
    private var participants: AudioDiarization? { currentRecord.diarization?.groupedByProfile }
    private var isFindingMatches: Bool { recognition.processingRecordIDs.contains(record.id) }
    private var hasUnlinkedSpeakers: Bool {
        speakerIDs.contains { analytics.profileID(speakerID: $0, recordID: record.id) == nil }
    }
    private var pendingMatchCount: Int {
        speakerIDs.filter { speaker in
            guard analytics.profileID(speakerID: speaker, recordID: record.id) == nil,
                  let suggestion = currentRecord.diarization?.speakerSuggestions?[String(speaker)] else { return false }
            return analytics.profile(withID: suggestion.profileID)?.voiceMatchingEnabled == true
        }.count
    }
    private var matchingStatus: String? {
        if !isFindingMatches, pendingMatchCount > 0 {
            return "\(pendingMatchCount) possible voice \(pendingMatchCount == 1 ? "match" : "matches") to review."
        }
        return recognition.statusMessages[record.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Speakers", systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Close speakers panel")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Clear voice matches link automatically across meetings. You can rename a profile or correct a person here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hasUnlinkedSpeakers {
                        Button(action: findMatches) {
                            HStack(spacing: 7) {
                                if isFindingMatches { ProgressView().controlSize(.small) }
                                else { Image(systemName: "person.crop.circle.badge.questionmark") }
                                Text(isFindingMatches ? "Updating speakers…" : "Update speaker profiles")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isFindingMatches || library.audioURL(for: currentRecord) == nil)
                        .accessibilityIdentifier("recording.speakers.find-matches")
                    }
                    if let status = matchingStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(participants?.speakerIDs ?? [], id: \.self) { speaker in
                        speakerCard(speaker)
                    }
                    if let undo = lastLinkUndo {
                        Button("Undo last speaker change") {
                            do {
                                try analytics.undoSpeakerReview(undo)
                                lastLinkUndo = nil
                            } catch { operationError = error.localizedDescription }
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("recording.speakers.undo")
                    }
                    Text("Changing a person here affects only this recording. Rename a profile to update its name everywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .accessibilityIdentifier("recording.speakers.panel")
        .sheet(item: $editor) { editing in
            AudioRecordingSpeakerLinkEditor(
                record: currentRecord, speakerID: editing.speakerID,
                analytics: analytics, isLabelOnly: editing.isLabelOnly,
                onRenameSpeaker: onRenameSpeaker,
                onLinked: { lastLinkUndo = $0 }
            )
        }
        .alert("Could not update speakers", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: { Text(operationError ?? "Please try again.") }
    }

    private func speakerCard(_ speaker: Int) -> some View {
        let linkedID = analytics.profileID(speakerID: speaker, recordID: record.id)
        let linked = linkedID.flatMap { analytics.profile(withID: $0) }
        let linkedSpeakers = linkedID.map { profileID in
            speakerIDs.filter { analytics.profileID(speakerID: $0, recordID: record.id) == profileID }
        } ?? [speaker]
        let suggestion = currentRecord.diarization?.speakerSuggestions?[String(speaker)]
        let suggested = suggestion.flatMap { analytics.profile(withID: $0.profileID) }
            .flatMap { $0.voiceMatchingEnabled ? $0 : nil }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(linked.map { profile in
                    profile.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
                } ?? "\(speaker + 1)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AudioTranscriptDetail.color(speaker))
                    .frame(width: 32, height: 32)
                    .background(AudioTranscriptDetail.color(speaker).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(linked?.name ?? currentRecord.diarization?.speakerName(speaker) ?? "Speaker \(speaker + 1)")
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(linked == nil ? "This recording only" : "Linked profile")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let excerpt = excerpt(for: speaker) {
                if let text = excerpt.text, !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 12) {
                    Button {
                        library.seekPlayback(for: currentRecord, to: excerpt.start)
                    } label: {
                        Label(AudioDiarization.timestamp(excerpt.start), systemImage: "play.fill")
                            .font(.caption.monospacedDigit())
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .disabled(library.audioURL(for: currentRecord) == nil)
                    .accessibilityLabel("Play speaker \(speaker + 1) excerpt at \(AudioDiarization.timestamp(excerpt.start))")
                    Button("View passages") { onViewTranscript(speaker) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                }
            }

            if let linked {
                HStack(spacing: 10) {
                    Button("View profile") { onOpenProfile(linked.id) }
                        .buttonStyle(.bordered).controlSize(.small)
                    Spacer(minLength: 0)
                    Menu {
                        if linkedSpeakers.count == 1 {
                            correctionActions(for: speaker)
                        } else {
                            ForEach(linkedSpeakers, id: \.self) { source in
                                Menu("Correct Speaker \(source + 1) link") {
                                    if let excerpt = excerpt(for: source, grouped: false) {
                                        Button("Play Speaker \(source + 1) sample") {
                                            library.seekPlayback(for: currentRecord, to: excerpt.start)
                                        }
                                        .disabled(library.audioURL(for: currentRecord) == nil)
                                        Divider()
                                    }
                                    correctionActions(for: source)
                                }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Correct speaker links for \(linked.name)")
                }
            } else if let suggested {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Possible voice match", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(suggested.name).font(.callout.weight(.semibold))
                    Text("Needs your review")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Confirm \(suggested.name)") { link(speaker, to: suggested.id) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                HStack {
                    Button("Choose someone else") {
                        editor = SpeakerEditor(speakerID: speaker, isLabelOnly: false)
                    }
                    Spacer(minLength: 0)
                    Button("Keep label") { dismissSuggestion(speaker) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            } else {
                HStack {
                    Button("Link to a profile") {
                        editor = SpeakerEditor(speakerID: speaker, isLabelOnly: false)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Spacer(minLength: 0)
                    Button { editor = SpeakerEditor(speakerID: speaker, isLabelOnly: true) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Edit label for this meeting")
                    .accessibilityLabel("Edit speaker \(speaker + 1) label for this meeting")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording.speakers.participant.\(linkedID ?? String(speaker))")
    }

    @ViewBuilder private func correctionActions(for speaker: Int) -> some View {
        Button("Change person for this meeting…") {
            editor = SpeakerEditor(speakerID: speaker, isLabelOnly: false)
        }
        Button("Unlink from this meeting") { unlink(speaker) }
    }

    private func excerpt(for speaker: Int, grouped: Bool = true) -> (start: Double, text: String?)? {
        let diarization = grouped ? participants : currentRecord.diarization
        let turns = diarization?.resolvedTranscriptSegments ?? []
        if let turn = turns.first(where: { $0.speakers == [speaker] })
            ?? turns.first(where: { $0.speakers.contains(speaker) }) {
            return (turn.start, turn.text)
        }
        return diarization?.segments.first(where: { $0.speaker == speaker })
            .map { ($0.start, nil) }
    }

    private func link(_ speaker: Int, to profileID: String) {
        do { lastLinkUndo = try analytics.linkSpeakerForReview(speakerID: speaker, recordID: record.id, profileID: profileID) }
        catch { operationError = error.localizedDescription }
    }

    private func unlink(_ speaker: Int) {
        do { try analytics.linkSpeaker(speakerID: speaker, recordID: record.id, profileID: nil) }
        catch { operationError = error.localizedDescription }
    }

    private func dismissSuggestion(_ speaker: Int) {
        do { try analytics.dismissSpeakerSuggestion(speakerID: speaker, recordID: record.id) }
        catch { operationError = error.localizedDescription }
    }

    private func findMatches() {
        Task { @MainActor in
            do { try await recognition.updateMeeting(recordID: record.id) }
            catch { operationError = error.localizedDescription }
        }
    }
}

private struct AudioRecordingSpeakerLinkEditor: View {
    let record: AudioTranscriptionRecord
    let speakerID: Int
    @ObservedObject var analytics: AudioAnalyticsStore
    let isLabelOnly: Bool
    let onRenameSpeaker: (Int, String) -> Void
    let onLinked: (AudioSpeakerReviewUndo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var createsProfile: Bool
    @State private var selectedProfileID: String
    @State private var name: String
    @State private var errorMessage: String?

    init(record: AudioTranscriptionRecord, speakerID: Int, analytics: AudioAnalyticsStore,
         isLabelOnly: Bool, onRenameSpeaker: @escaping (Int, String) -> Void,
         onLinked: @escaping (AudioSpeakerReviewUndo) -> Void) {
        self.record = record
        self.speakerID = speakerID
        self.analytics = analytics
        self.isLabelOnly = isLabelOnly
        self.onRenameSpeaker = onRenameSpeaker
        self.onLinked = onLinked
        _createsProfile = State(initialValue: analytics.speakerProfiles.isEmpty)
        _selectedProfileID = State(initialValue: analytics.profileID(speakerID: speakerID, recordID: record.id) ?? "")
        let savedName = record.diarization?.speakerNames?[String(speakerID)] ?? ""
        _name = State(initialValue: savedName)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        isLabelOnly || (createsProfile ? !trimmedName.isEmpty : !selectedProfileID.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isLabelOnly ? "Edit meeting label" : "Who is Speaker \(speakerID + 1)?")
                .font(.title3.weight(.semibold))
            Text(isLabelOnly
                 ? "This label applies only to this recording. Link a profile to keep track of the same person across meetings."
                 : "This updates only the speaker link in this recording. Other meetings keep their current links.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isLabelOnly {
                Picker("Profile", selection: $createsProfile) {
                    Text("Existing profile").tag(false)
                    Text("New profile").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if isLabelOnly || createsProfile {
                TextField(isLabelOnly ? "Speaker \(speakerID + 1)" : "Person’s name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(isLabelOnly ? "Speaker label for this meeting" : "New speaker profile name")
                    .onSubmit { if canSave { save() } }
                Text(isLabelOnly ? "Clear the name to restore Speaker \(speakerID + 1)."
                     : "Creates a reusable profile and links it to this voice. Voice recognition can be enabled from the profile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if analytics.speakerProfiles.isEmpty {
                Text("No speaker profiles yet. Create a new profile to link this person.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Person", selection: $selectedProfileID) {
                    Text("Choose a profile").tag("")
                    ForEach(analytics.speakerProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                if record.diarization?.speakerIDs.contains(where: {
                    $0 != speakerID && analytics.profileID(speakerID: $0, recordID: record.id) == selectedProfileID
                }) == true, let profile = analytics.profile(withID: selectedProfileID) {
                    Text("Merges this speaker into \(profile.name), updating the saved speaker assignments for this recording.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isLabelOnly ? "Save label" : createsProfile ? "Create and link" : "Save meeting link", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func save() {
        guard canSave else { return }
        do {
            if isLabelOnly {
                onRenameSpeaker(speakerID, trimmedName)
            } else {
                if createsProfile {
                    onLinked(try analytics.createAndLinkSpeakerForReview(name: trimmedName,
                                                                  speakerID: speakerID, recordID: record.id))
                } else {
                    onLinked(try analytics.linkSpeakerForReview(speakerID: speakerID, recordID: record.id,
                                              profileID: selectedProfileID))
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
