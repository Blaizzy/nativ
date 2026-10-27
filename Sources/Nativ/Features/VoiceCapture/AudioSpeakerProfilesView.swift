import SwiftUI

/// A person has one profile, even when diarization assigns a different speaker
/// number in each recording. Recording links remain the source of the history.
@MainActor
struct AudioSpeakerProfilesView: View {
    @ObservedObject var store: AudioAnalyticsStore
    @ObservedObject var recognition: AudioSpeakerRecognition
    @ObservedObject var library: AudioCaptureLibrary
    @Binding var selectedProfileID: String?
    let onOpenRecording: (_ recordID: String, _ profileID: String) -> Void
    let onReviewMatch: (_ recordID: String) -> Void

    @State private var section: DirectorySection = .people
    @State private var reviewSelectionID: String?
    @State private var deferredReviewIDs = Set<String>()
    @State private var searchText = ""
    @State private var showsRecordingPicker = false

    private enum DirectorySection { case people, review }
    @State private var editor: ProfileEditorDestination?
    @State private var profileToDelete: AudioSpeakerProfile?
    @State private var errorMessage: String?

    private enum ProfileEditorDestination: Identifiable {
        case create
        case rename(AudioSpeakerProfile)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let profile): profile.id
            }
        }
    }

    private var selectedProfile: AudioSpeakerProfile? {
        selectedProfileID.flatMap { store.profile(withID: $0) }
    }

    private var visibleProfiles: [AudioSpeakerProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.speakerProfiles.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if let selectedProfile {
                GeometryReader { geometry in
                    ScrollView {
                        profileDetail(selectedProfile, stacksPanels: geometry.size.width < 850)
                            .padding(24)
                            .frame(maxWidth: 1_200, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            } else {
                directory
                    .padding(24)
                    .frame(maxWidth: 1_200, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audio.speaker-profiles")
        .sheet(isPresented: $showsRecordingPicker) {
            AudioSpeakerRecordingPicker(store: store, library: library) { recordIDs in
                Task { await recognition.processMeetings(recordIDs: recordIDs) }
            }
        }
        .sheet(item: $editor) { destination in
            switch destination {
            case .create:
                AudioSpeakerProfileNameSheet(name: "", isCreating: true) { name in
                    let profile = try store.createSpeakerProfile(name: name)
                    selectedProfileID = profile.id
                }
            case .rename(let profile):
                AudioSpeakerProfileNameSheet(name: profile.name, isCreating: false) { name in
                    try store.renameSpeakerProfile(id: profile.id, name: name)
                }
            }
        }
        .alert("Delete speaker profile?", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), presenting: profileToDelete) { profile in
            Button("Delete profile", role: .destructive) {
                do {
                    try store.deleteSpeakerProfile(id: profile.id)
                    selectedProfileID = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                profileToDelete = nil
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: { profile in
            Text("Remove \(profile.name)’s profile and its meeting links? Your recordings, audio, and transcripts will be kept.")
        }
        .alert("Could not update speaker profile", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .onChange(of: store.speakerProfiles) { _, _ in
            if let id = selectedProfileID, store.profile(withID: id) == nil {
                selectedProfileID = nil
            }
        }
        .onChange(of: selectedProfileID) { _, _ in library.stopExcerptPlayback() }
        .onDisappear { library.stopExcerptPlayback() }
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Speakers").font(.title2.weight(.semibold))
                    Text("People you meet, connected across recordings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    store.refreshSpeakerDirectory()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh the speaker list without processing recordings")
                .accessibilityIdentifier("speaker-profiles.refresh")
                Button { showsRecordingPicker = true } label: {
                    Label("Process recordings", systemImage: "waveform.badge.magnifyingglass")
                }
                .disabled(recognition.isUpdatingMeetings || library.isBusy)
                .accessibilityIdentifier("speaker-profiles.process-recordings")
                Button { editor = .create } label: {
                    Label("New profile", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("speaker-profiles.create")
            }

            meetingUpdateStatus

            HStack(spacing: 4) {
                directoryTab("People", section: .people, count: store.speakerProfiles.count)
                directoryTab("Review", section: .review, count: store.speakerReviewItems.count)
            }
            .padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            if section == .review {
                AudioSpeakerReviewInbox(
                    store: store, library: library,
                    selectionID: $reviewSelectionID, deferredIDs: $deferredReviewIDs,
                    onOpenRecording: onReviewMatch
                )
            } else {
                ScrollView {
                    peopleDirectory
                }
            }
        }
    }

    @ViewBuilder private var meetingUpdateStatus: some View {
        let progress = recognition.meetingProgress
        let paused = recognition.isMeetingUpdatePaused
        let running = recognition.isUpdatingMeetings
        if running || paused || progress.total > 0 || recognition.libraryStatus != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label(paused ? (running ? "Pausing speaker updates…" : "Speaker updates paused")
                          : running ? "Updating speaker profiles" : "Speaker update complete",
                          systemImage: paused ? "pause.circle" : running ? "waveform" : "checkmark.circle")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    if paused {
                        Button {
                            Task { await recognition.resumeMeetingUpdates() }
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .disabled(running)
                        .accessibilityIdentifier("speaker-profiles.resume-updates")
                    } else if running {
                        Button { recognition.pauseMeetingUpdates() } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .accessibilityIdentifier("speaker-profiles.pause-updates")
                    }
                }
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Speaker profile update progress")
                        .accessibilityValue("\(progress.completed) of \(progress.total) meetings checked, \(progress.remaining) remaining")
                        .accessibilityIdentifier("speaker-profiles.update-progress")
                    HStack(spacing: 12) {
                        Text("\(progress.completed) of \(progress.total) meetings checked")
                        if progress.failed > 0 {
                            Text("\(progress.failed) need retry").foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                        Text("\(progress.remaining) remaining")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let status = recognition.libraryStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if paused {
                    Text("Resume when you’re ready. New meetings still get speaker matching automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("speaker-profiles.update-status")
        }
    }

    private func directoryTab(_ title: String, section destination: DirectorySection, count: Int) -> some View {
        Button {
            library.stopExcerptPlayback()
            section = destination
        } label: {
            HStack(spacing: 8) {
                Text(title).fontWeight(.medium)
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(section == destination ? 0.13 : 0.05), in: Capsule())
            }
            .font(.callout)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .foregroundStyle(section == destination ? Color.white : Color.primary)
            .background(section == destination ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(section == destination ? [.isSelected] : [])
        .accessibilityIdentifier("speaker-profiles.tab.\(destination == .people ? "people" : "review")")
    }

    private var peopleDirectory: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.speakerProfiles.isEmpty {
                emptyDirectory
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a speaker", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Find a speaker")
                        .accessibilityIdentifier("speaker-profiles.search")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear speaker search")
                    }
                }
                .padding(11)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                .frame(maxWidth: 360)

                if visibleProfiles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 230)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleProfiles.enumerated()), id: \.element.id) { index, profile in
                            directoryRow(profile)
                            if index < visibleProfiles.count - 1 {
                                Divider().padding(.leading, 80)
                            }
                        }
                    }
                    .speakerProfilePanel()
                }

                HStack(alignment: .top, spacing: 20) {
                    Text("New meetings update profiles automatically. Use Process recordings to choose older meetings.")
                    Spacer(minLength: 0)
                    Text("\(store.speakerProfiles.count.formatted()) \(store.speakerProfiles.count == 1 ? "profile" : "profiles") · Stored on this Mac")
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyDirectory: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 34)).foregroundStyle(Color.accentColor)
                .padding(20)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 7) {
                Text("A familiar name in every meeting").font(.title3.weight(.semibold))
                Text("Nativ diarizes and transcribes new meetings first, then identifies speakers. Choose Process recordings to include older meetings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button("Create your first profile") { editor = .create }
                .buttonStyle(.borderedProminent)
            Label("Profiles and meeting links are stored on this Mac.", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 340)
        .speakerProfilePanel()
    }

    private func directoryRow(_ profile: AudioSpeakerProfile) -> some View {
        let history = linkedRecords(for: profile)
        return Button {
            selectedProfileID = profile.id
        } label: {
            HStack(spacing: 16) {
                AudioSpeakerProfileAvatar(name: profile.name, profileID: profile.id)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.body.weight(.semibold)).lineLimit(2)
                    if let lastMeeting = history.first {
                        Text("Last meeting \(lastMeeting.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Ready to link from a recording")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(meetingCount(history.count)).font(.callout)
                    if profile.needsVoiceReenrollment {
                        Label("Voice profile needs refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    } else if profile.voiceMatchingEnabled {
                        Label("Automatic matching on", systemImage: "waveform")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(meetingCount(history.count))")
        .accessibilityHint("Open speaker profile")
        .accessibilityIdentifier("speaker-profiles.profile.\(profile.id)")
    }

    private func profileDetail(_ profile: AudioSpeakerProfile, stacksPanels: Bool) -> some View {
        let history = linkedRecords(for: profile)
        return VStack(alignment: .leading, spacing: 24) {
            Button { selectedProfileID = nil } label: {
                Label("All speakers", systemImage: "chevron.left")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("speaker-profiles.back")

            HStack(alignment: .center, spacing: 18) {
                AudioSpeakerProfileAvatar(name: profile.name, profileID: profile.id, size: 64)
                VStack(alignment: .leading, spacing: 7) {
                    Text(profile.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(meetingCount(history.count))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { editor = .rename(profile) } label: {
                    Label("Edit profile", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("speaker-profiles.edit")
            }

            meetingUpdateStatus

            pendingMatches(profileID: profile.id)

            if stacksPanels {
                VStack(alignment: .leading, spacing: 24) {
                    meetingHistory(profile, records: history)
                    profileInformation(profile)
                }
            } else {
                HStack(alignment: .top, spacing: 24) {
                    meetingHistory(profile, records: history).frame(minWidth: 0, maxWidth: .infinity)
                    profileInformation(profile).frame(width: 270)
                }
            }

            if let latest = history.first {
                Button {
                    onOpenRecording(latest.id, profile.id)
                } label: {
                    Label("Open latest linked meeting", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("speaker-profiles.latest")
            }
        }
    }

    @ViewBuilder private func pendingMatches(profileID: String?) -> some View {
        let matches = store.speakerReviewItems.filter { profileID == nil || $0.suggestion?.profileID == profileID }
        if !matches.isEmpty {
            HStack(spacing: 16) {
                Label("\(matches.count) possible voice \(matches.count == 1 ? "match" : "matches")", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.callout)
                Spacer()
                Button("Review speakers") {
                    reviewSelectionID = matches.first?.id
                    if let id = reviewSelectionID { deferredReviewIDs.remove(id) }
                    section = .review
                    selectedProfileID = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(16)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func meetingHistory(_ profile: AudioSpeakerProfile, records: [AudioTranscriptionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Meeting history").font(.headline)
                Spacer()
                Text("\(records.count.formatted()) linked").font(.caption).foregroundStyle(.secondary)
            }
            if records.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No linked meetings yet", systemImage: "link")
                        .font(.body.weight(.medium))
                    Text("Open a recording’s Speakers panel and choose this profile for the right speaker. That meeting will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .speakerProfilePanel()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(records) { record in
                        meetingRow(record, profile: profile)
                    }
                }
            }
            Text("A speaker number belongs to one recording. This profile keeps the same person connected across meetings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func meetingRow(_ record: AudioTranscriptionRecord, profile: AudioSpeakerProfile) -> some View {
        let speakerIDs = linkedSpeakerIDs(in: record, profile: profile)
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                onOpenRecording(record.id, profile.id)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.displayTitle).font(.body.weight(.semibold)).lineLimit(2)
                        Text(meetingMetadata(record)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open transcript filtered to \(profile.name)")
            .accessibilityIdentifier("speaker-profiles.meeting.\(record.id)")

            Label(profile.name, systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Voice segments").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let speakerID = speakerIDs.first {
                AudioSpeakerLinkedSegments(record: record, speakerID: speakerID,
                                           profileName: profile.name, library: library)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .speakerProfilePanel()
    }

    private func profileInformation(_ profile: AudioSpeakerProfile) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Profile details").font(.headline)
                informationRow(
                    title: "Meeting links", symbol: "person.crop.circle.badge.checkmark",
                    detail: "Clear voice matches link automatically. You can correct the person in any recording."
                )
                Divider()
                voiceMatchingControls(profile)
                Divider()
                informationRow(
                    title: "One name across meetings", symbol: "person.text.rectangle",
                    detail: "Renaming this profile updates the speaker label in every linked meeting."
                )
                Divider()
                informationRow(
                    title: "Stored on this Mac", symbol: "internaldrive",
                    detail: "Created \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))."
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .speakerProfilePanel()

            Text("A mistaken match? Change the person in that meeting’s Speakers panel. Other meeting links stay the same.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Delete profile", role: .destructive) { profileToDelete = profile }
                .buttonStyle(.plain).font(.caption)
                .disabled(recognition.processingProfileIDs.contains(profile.id))
                .accessibilityIdentifier("speaker-profiles.delete")
        }
    }

    private func voiceMatchingControls(_ profile: AudioSpeakerProfile) -> some View {
        let isPreparing = recognition.processingProfileIDs.contains(profile.id)
        let hasLinkedMeetings = !store.records(linkedToProfileID: profile.id).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Match automatically by voice").font(.callout.weight(.medium))
                Spacer(minLength: 4)
                if isPreparing {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Preparing voice profile")
                } else {
                    Toggle("Match automatically by voice", isOn: Binding(
                        get: { profile.voiceMatchingEnabled },
                        set: { enabled in updateVoiceMatching(enabled, profile: profile) }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!hasLinkedMeetings && !profile.voiceMatchingEnabled)
                    .accessibilityIdentifier("speaker-profiles.voice-matching")
                }
            }
            Text("Use this person’s saved voice signature to link clear matches in new and past meetings. Ambiguous voices stay unlinked.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isPreparing {
                Text("Preparing the voice model and learning from linked recordings…")
                    .font(.caption).foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else if profile.needsVoiceReenrollment {
                Text("The voice model has been updated. Nativ will refresh this voice profile from linked recordings before finding new matches.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh voice profile") { updateVoiceMatching(true, profile: profile) }
                    .buttonStyle(.link)
                    .disabled(!hasLinkedMeetings)
                    .accessibilityIdentifier("speaker-profiles.refresh-voice")
            } else if profile.voiceMatchingEnabled {
                Text("Voice profile stored on this Mac. Turning this off removes the saved voice signature and keeps your meeting links.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasLinkedMeetings {
                Text("Downloads a voice model (about 42 MB) the first time. Voice matching runs locally.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Link a recording to this profile first so Nativ can learn from confirmed speech.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func updateVoiceMatching(_ enabled: Bool, profile: AudioSpeakerProfile) {
        if enabled {
            Task { @MainActor in
                do {
                    try await recognition.enableVoiceMatching(profileID: profile.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } else {
            do {
                try recognition.disableVoiceMatching(profileID: profile.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func informationRow(title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkedRecords(for profile: AudioSpeakerProfile) -> [AudioTranscriptionRecord] {
        store.records(linkedToProfileID: profile.id).sorted { $0.recordedAt > $1.recordedAt }
    }

    private func linkedSpeakerIDs(in record: AudioTranscriptionRecord, profile: AudioSpeakerProfile) -> [Int] {
        (record.diarization?.speakerIDs ?? []).filter {
            store.profileID(speakerID: $0, recordID: record.id) == profile.id
        }
    }

    private func meetingCount(_ count: Int) -> String {
        "\(count.formatted()) linked \(count == 1 ? "meeting" : "meetings")"
    }

    private func meetingMetadata(_ record: AudioTranscriptionRecord) -> String {
        var parts = [record.recordedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.durationSeconds { parts.append(NativFormatting.clockDuration(duration)) }
        return parts.joined(separator: " · ")
    }
}

/// The profile ID makes this avatar stable when a name or meeting label changes.
struct AudioSpeakerProfileAvatar: View {
    let name: String
    let profileID: String
    var size: CGFloat = 40

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]
        // Avoid Swift's process-randomized Hasher so colors survive app restarts.
        let index = profileID.utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
        return palette[index]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.32, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.29))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct AudioSpeakerProfileNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameIsFocused: Bool
    @State private var name: String
    @State private var errorMessage: String?
    let isCreating: Bool
    let onSave: (String) throws -> Void

    init(name: String, isCreating: Bool, onSave: @escaping (String) throws -> Void) {
        _name = State(initialValue: name)
        self.isCreating = isCreating
        self.onSave = onSave
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isCreating ? "New speaker profile" : "Edit speaker profile")
                    .font(.title3.weight(.semibold))
                Text(isCreating
                     ? "Use this person’s name to connect their speakers across recordings."
                     : "This name will appear in every meeting linked to the profile.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(.callout.weight(.medium))
                TextField("Person’s name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameIsFocused)
                    .onSubmit(save)
                    .accessibilityIdentifier("speaker-profile.name")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create profile" : "Save name", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("speaker-profile.save")
            }
        }
        .padding(26)
        .frame(width: 410)
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        do {
            try onSave(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension View {
    func speakerProfilePanel() -> some View {
        background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }
}

/// The same bounded preview control is used in Review and profile history.
@MainActor
struct AudioSpeakerExcerptButton: View {
    let record: AudioTranscriptionRecord?
    let excerpt: AudioSpeakerReviewExcerpt?
    let speakerName: String
    @ObservedObject var library: AudioCaptureLibrary
    let identifier: String
    var compact = false

    private var canPlay: Bool {
        record.flatMap { library.audioURL(for: $0) } != nil && excerpt != nil
    }
    private var isPlaying: Bool {
        guard let record, let excerpt else { return false }
        return library.isPlayingExcerpt(for: record, start: excerpt.start, end: excerpt.end)
    }

    var body: some View {
        Button {
            guard let record, let excerpt else { return }
            library.toggleExcerptPlayback(for: record, start: excerpt.start, end: excerpt.end)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout).foregroundStyle(.white)
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                    .background(canPlay ? Color.accentColor : .gray, in: Circle())
                Text(excerpt.map { "\(isPlaying ? "Pause" : "Listen") · \(String(format: "%.1f", $0.end - $0.start)) sec" }
                     ?? "No preview")
                    .font(.callout.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .padding(7)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!canPlay)
        .accessibilityLabel("\(isPlaying ? "Pause" : "Play") \(speakerName) voice sample")
        .accessibilityIdentifier(identifier)
        .help(canPlay ? "Preview \(speakerName)’s voice; stops at the end of the clip"
              : "No playable solo speech is available")
    }
}

@MainActor
struct AudioSpeakerLinkedSegments: View {
    let record: AudioTranscriptionRecord
    let speakerID: Int
    let profileName: String
    @ObservedObject var library: AudioCaptureLibrary
    @State private var previews: [Preview] = []

    private struct Preview: Identifiable {
        let excerpt: AudioSpeakerReviewExcerpt
        let quote: String?
        var id: Double { excerpt.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if previews.isEmpty {
                Label("No solo voice preview available for Speaker \(speakerID + 1)", systemImage: "waveform.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(previews) { preview in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            AudioSpeakerExcerptButton(record: record, excerpt: preview.excerpt,
                                speakerName: profileName, library: library,
                                identifier: "speaker-profiles.segment.\(record.id).\(speakerID).\(preview.excerpt.start)",
                                compact: true)
                            Text("\(AudioDiarization.timestamp(preview.excerpt.start))–\(AudioDiarization.timestamp(preview.excerpt.end))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        if let quote = preview.quote {
                            Text("“\(quote)”").font(.callout).foregroundStyle(.secondary)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onChange(of: record.diarization, initial: true) { _, diarization in
            guard let diarization = diarization?.groupedByProfile else { previews = []; return }
            previews = AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: speakerID).map { excerpt in
                Preview(excerpt: excerpt, quote: AudioSpeakerReviewExcerpt.transcriptQuote(
                    in: diarization, speakerID: speakerID, excerpt: excerpt
                ))
            }
        }
    }
}
