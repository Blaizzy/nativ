import SwiftUI

/// Review is a decision about one voice in one recording, not an entire meeting.
@MainActor
struct AudioSpeakerReviewInbox: View {
    @ObservedObject var store: AudioAnalyticsStore
    @ObservedObject var library: AudioCaptureLibrary
    @Binding var selectionID: String?
    @Binding var deferredIDs: Set<String>
    let onOpenRecording: (String) -> Void

    @State private var query = ""
    @State private var filter: ReviewFilter = .all
    @State private var chosenProfileID: String?
    @State private var showsProfilePicker = false
    @State private var showsCompactQueue = false
    @State private var creationItem: AudioSpeakerReviewItem?
    @State private var lastDecision: AudioSpeakerReviewUndo?
    @State private var lastDecisionName = ""
    @State private var errorMessage: String?

    private enum ReviewFilter: String, CaseIterable, Identifiable {
        case all = "All reasons"
        case possibleMatch = "Possible matches"
        case noMatch = "Choose a person"
        case insufficientSpeech = "Too little speech"
        var id: Self { self }

        func includes(_ item: AudioSpeakerReviewItem) -> Bool {
            switch self {
            case .all: true
            case .possibleMatch: item.reason == .possibleMatch
            case .noMatch: item.reason == .noMatch
            case .insufficientSpeech: item.reason == .insufficientSpeech
            }
        }
    }

    private var items: [AudioSpeakerReviewItem] { store.speakerReviewItems }
    private var visibleItems: [AudioSpeakerReviewItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            !deferredIDs.contains($0.id) && filter.includes($0)
                && (search.isEmpty || [$0.speakerName, $0.recordingTitle, $0.suggestedProfileName ?? ""]
                    .contains { $0.localizedStandardContains(search) })
        }
    }
    private var selectedItem: AudioSpeakerReviewItem? {
        visibleItems.first { $0.id == selectionID } ?? visibleItems.first
    }
    private var deferredCount: Int { items.filter { deferredIDs.contains($0.id) }.count }

    var body: some View {
        VStack(spacing: 12) {
            if items.isEmpty {
                emptyInbox
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 780 {
                        let queueWidth = min(320, max(250, geometry.size.width * 0.30))
                        HStack(alignment: .top, spacing: 14) {
                            queue.frame(width: queueWidth)
                            detail(availableWidth: geometry.size.width - queueWidth - 14)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 12) {
                            compactQueue
                            detail(availableWidth: geometry.size.width)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            if lastDecision != nil { undoBar }
        }
        .onChange(of: visibleItems.map(\.id), initial: true) { _, ids in
            if selectionID == nil || !ids.contains(selectionID ?? "") { selectionID = ids.first }
        }
        .onChange(of: selectionID) { _, _ in
            library.stopExcerptPlayback()
            chosenProfileID = nil
            showsProfilePicker = false
            showsCompactQueue = false
        }
        .onDisappear { library.stopExcerptPlayback() }
        .sheet(item: $creationItem) { item in
            AudioSpeakerReviewNameSheet(speakerName: item.speakerName) { name in
                let undo = try store.createAndLinkSpeakerForReview(
                    name: name, speakerID: item.speakerID, recordID: item.recordID,
                    expectedFingerprint: item.segmentationFingerprint
                )
                completed(undo, name: store.profile(withID: undo.linkedProfileID)?.name ?? name, item: item)
            }
        }
        .alert("Could not update speaker", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speaker-review.inbox")
    }

    private var compactQueue: some View {
        HStack(spacing: 12) {
            Button { showsCompactQueue = true } label: {
                Label("Review queue · \(visibleItems.count)", systemImage: "sidebar.left")
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $showsCompactQueue, arrowEdge: .bottom) {
                queue.frame(width: 320, height: 460).padding(8)
            }
            .accessibilityIdentifier("speaker-review.compact-queue")
            Spacer(minLength: 0)
            if let selectedItem {
                Text(selectedItem.speakerName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Needs your attention").font(.headline)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a speaker or meeting", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("speaker-review.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear review search")
                    }
                }
                .font(.callout).padding(9)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                Picker("Review reason", selection: $filter) {
                    ForEach(ReviewFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityIdentifier("speaker-review.filter")
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(visibleItems) { item in queueRow(item) }
                }
                .padding(6)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("\(visibleItems.count) \(visibleItems.count == 1 ? "speaker" : "speakers") in \(Set(visibleItems.map(\.recordID)).count) \(Set(visibleItems.map(\.recordID)).count == 1 ? "meeting" : "meetings")")
                    .font(.caption).foregroundStyle(.secondary)
                if deferredCount > 0 {
                    Button("Bring back \(deferredCount) set aside") { deferredIDs.removeAll() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("speaker-review.restore-later")
                }
            }
            .padding(14)
        }
        .reviewPanel()
    }

    private func queueRow(_ item: AudioSpeakerReviewItem) -> some View {
        let selected = selectedItem?.id == item.id
        return Button { selectionID = item.id; showsCompactQueue = false } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.fill")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.06), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.speakerName).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(item.recordingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("Saved \(item.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    reasonBadge(item)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.speakerName), \(item.recordingTitle), \(reasonLabel(item))")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("speaker-review.item.\(item.id)")
    }

    @ViewBuilder private func detail(availableWidth: CGFloat) -> some View {
        if let item = selectedItem {
            ScrollView {
                reviewDetail(item, stacksClips: availableWidth < 560)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .reviewPanel()
            .popover(isPresented: $showsProfilePicker, arrowEdge: .leading) {
                AudioSpeakerReviewProfilePicker(profiles: store.speakerProfiles) { profileID in
                    library.stopExcerptPlayback()
                    chosenProfileID = profileID
                    showsProfilePicker = false
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: deferredCount > 0 ? "clock" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 28)).foregroundStyle(.secondary)
                Text(deferredCount > 0 && query.isEmpty && filter == .all
                     ? "All set aside for now" : "No speakers match this filter")
                    .font(.headline)
                if !query.isEmpty || filter != .all {
                    Button("Clear filters") { query = ""; filter = .all }
                } else if deferredCount > 0 {
                    Text("Set-aside speakers stay available in this session.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Bring back speakers") { deferredIDs.removeAll() }
                }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .reviewPanel()
        }
    }

    private func reviewDetail(_ item: AudioSpeakerReviewItem, stacksClips: Bool) -> some View {
        let profile = selectedProfile(for: item)
        let record = store.record(withID: item.recordID)
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.recordingTitle).font(.callout).foregroundStyle(.secondary)
                    Text("Saved \(item.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { deferItem(item) } label: { Label("Later", systemImage: "arrow.right") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .help("Set this speaker aside for this session")
                    .accessibilityIdentifier("speaker-review.later")
            }
            VStack(alignment: .leading, spacing: 10) {
                reasonBadge(item)
                Text(profile.map { "Is \(item.speakerName) \($0.name)?" } ?? "Who is \(item.speakerName)?")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailExplanation(item, selectedProfile: profile))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Choose from the actual pane width: a quote's intrinsic width
            // must not force the comparison into a vertical layout.
            if stacksClips {
                VStack(spacing: 14) {
                    currentVoice(item, record: record)
                    referenceVoice(profile, excluding: item.recordID)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    currentVoice(item, record: record).frame(minWidth: 0, maxWidth: .infinity)
                    referenceVoice(profile, excluding: item.recordID).frame(minWidth: 0, maxWidth: .infinity)
                }
            }

            Button {
                library.stopExcerptPlayback()
                onOpenRecording(item.recordID)
            } label: { Label("Open meeting", systemImage: "arrow.up.right.square") }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("speaker-review.open-meeting")

            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if let profile {
                    Button("Link to \(profile.name)") { link(item, to: profile) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("speaker-review.link")
                }
                secondaryActions(item, hasProfile: profile != nil)
                Text("Applies only to \(item.speakerName) in this meeting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func secondaryActions(_ item: AudioSpeakerReviewItem, hasProfile: Bool) -> some View {
        let choose = Button {
            library.stopExcerptPlayback()
            showsProfilePicker = true
        } label: {
            Label(hasProfile ? "Choose another profile" : "Choose a profile", systemImage: "person.crop.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("speaker-review.choose-profile")
        let create = Button("Create profile") {
            library.stopExcerptPlayback()
            creationItem = item
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("speaker-review.create-profile")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { choose; create }
            VStack(alignment: .leading, spacing: 14) { choose; create }
        }
    }

    private func currentVoice(_ item: AudioSpeakerReviewItem, record: AudioTranscriptionRecord?) -> some View {
        AudioSpeakerReviewVoiceCard(
            title: "This meeting", subtitle: item.speakerName,
            record: record, excerpt: item.excerpt, quote: item.transcriptQuote,
            library: library, identifier: "speaker-review.listen-current"
        )
    }

    @ViewBuilder private func referenceVoice(_ profile: AudioSpeakerProfile?, excluding recordID: String) -> some View {
        if let profile {
            let reference = referenceClip(for: profile, excluding: recordID)
            AudioSpeakerReviewVoiceCard(
                title: profile.name,
                subtitle: reference?.record.displayTitle ?? "No comparison clip available",
                record: reference?.record, excerpt: reference?.excerpt, quote: reference?.quote,
                library: library, identifier: "speaker-review.listen-reference"
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Compare with a profile").font(.headline)
                Text("Choose a person to hear their voice from another linked meeting.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose a profile") { showsProfilePicker = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("speaker-review.compare-profile")
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 195, alignment: .topLeading)
            .reviewPanel()
        }
    }

    private struct ReferenceClip {
        let record: AudioTranscriptionRecord
        let excerpt: AudioSpeakerReviewExcerpt
        let quote: String?
    }

    private func referenceClip(for profile: AudioSpeakerProfile, excluding recordID: String) -> ReferenceClip? {
        // Prefer the saved enrollment recording, while checking the link still
        // belongs to this person. Fall back to another currently linked meeting.
        let samples = profile.voiceSamples ?? []
        let records = store.records(linkedToProfileID: profile.id).sorted { left, right in
            let leftIsSource = samples.contains { $0.recordID == left.id }
            let rightIsSource = samples.contains { $0.recordID == right.id }
            return leftIsSource != rightIsSource ? leftIsSource : left.recordedAt > right.recordedAt
        }
        for record in records where record.id != recordID && library.audioURL(for: record) != nil {
            guard let diarization = record.diarization else { continue }
            for speakerID in diarization.speakerIDs where store.profileID(speakerID: speakerID, recordID: record.id) == profile.id {
                if let excerpt = AudioSpeakerReviewExcerpt.best(in: diarization, speakerID: speakerID) {
                    return ReferenceClip(record: record, excerpt: excerpt,
                                         quote: AudioSpeakerReviewExcerpt.transcriptQuote(in: diarization, speakerID: speakerID, excerpt: excerpt))
                }
            }
        }
        return nil
    }

    private func selectedProfile(for item: AudioSpeakerReviewItem) -> AudioSpeakerProfile? {
        (chosenProfileID ?? item.suggestion?.profileID).flatMap { store.profile(withID: $0) }
    }

    private func reasonLabel(_ item: AudioSpeakerReviewItem) -> String {
        switch item.reason {
        case .possibleMatch: "Possible match"
        case .noMatch: "Choose a person"
        case .insufficientSpeech: "Too little speech"
        }
    }

    private func reasonBadge(_ item: AudioSpeakerReviewItem) -> some View {
        Text(reasonLabel(item)).font(.caption2.weight(.medium))
            .foregroundStyle(item.reason == .possibleMatch ? Color.orange : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(item.reason == .possibleMatch ? Color.orange.opacity(0.10) : Color.primary.opacity(0.05), in: Capsule())
    }

    private func detailExplanation(_ item: AudioSpeakerReviewItem, selectedProfile: AudioSpeakerProfile?) -> String {
        if item.reason == .insufficientSpeech {
            return "There isn’t enough clear solo speech for voice matching. You can identify this speaker yourself or leave it for later."
        }
        if selectedProfile != nil {
            return "Listen to both clips before linking this voice to a person."
        }
        return "No profile is suggested for this voice. Choose someone you know or create a new profile."
    }

    private var emptyInbox: some View {
        VStack(spacing: 15) {
            Image(systemName: "checkmark.circle").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("No speakers waiting for review").font(.title3.weight(.semibold))
            Text("Speakers that need your input appear here after their meetings are diarized and transcribed.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .reviewPanel()
    }

    private var undoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Linked to \(lastDecisionName)").font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: undo).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("speaker-review.undo")
            Button { lastDecision = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss last decision")
        }
        .padding(12).reviewPanel()
    }

    private func link(_ item: AudioSpeakerReviewItem, to profile: AudioSpeakerProfile) {
        do {
            let undo = try store.linkSpeakerForReview(
                speakerID: item.speakerID, recordID: item.recordID, profileID: profile.id,
                expectedFingerprint: item.segmentationFingerprint
            )
            completed(undo, name: profile.name, item: item)
        } catch { errorMessage = error.localizedDescription }
    }

    private func completed(_ undo: AudioSpeakerReviewUndo, name: String, item: AudioSpeakerReviewItem) {
        library.stopExcerptPlayback()
        lastDecision = undo
        lastDecisionName = name
        deferredIDs.remove(item.id)
        chosenProfileID = nil
        selectionID = visibleItems.first?.id
    }

    private func deferItem(_ item: AudioSpeakerReviewItem) {
        library.stopExcerptPlayback()
        deferredIDs.insert(item.id)
        selectionID = visibleItems.first?.id
    }

    private func undo() {
        guard let decision = lastDecision else { return }
        do {
            try store.undoSpeakerReview(decision)
            library.stopExcerptPlayback()
            query = ""
            filter = .all
            if let restored = items.first(where: { $0.recordID == decision.recordID && $0.speakerID == decision.speakerID }) {
                deferredIDs.remove(restored.id)
                selectionID = restored.id
            }
            chosenProfileID = nil
            lastDecision = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private struct AudioSpeakerReviewVoiceCard: View {
    let title: String
    let subtitle: String
    let record: AudioTranscriptionRecord?
    let excerpt: AudioSpeakerReviewExcerpt?
    let quote: String?
    @ObservedObject var library: AudioCaptureLibrary
    let identifier: String

    private var canPlay: Bool {
        record.flatMap { library.audioURL(for: $0) } != nil && excerpt != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            AudioSpeakerExcerptButton(record: record, excerpt: excerpt, speakerName: title,
                                      library: library, identifier: identifier)
            if !canPlay, excerpt != nil {
                Text("The audio file isn’t available.").font(.caption).foregroundStyle(.secondary)
            }
            if let quote, !quote.isEmpty {
                Text("“\(quote)”").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(4).textSelection(.enabled)
            } else if let excerpt {
                Text("From \(AudioDiarization.timestamp(excerpt.start)) in the recording")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 195, alignment: .topLeading)
        .reviewPanel()
    }
}

private struct AudioSpeakerReviewProfilePicker: View {
    let profiles: [AudioSpeakerProfile]
    let onChoose: (String) -> Void
    @State private var query = ""

    private var matches: [AudioSpeakerProfile] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a person").font(.headline)
            TextField("Search profiles", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speaker-review.profile-search")
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(matches) { profile in
                        Button { onChoose(profile.id) } label: {
                            HStack(spacing: 10) {
                                AudioSpeakerProfileAvatar(name: profile.name, profileID: profile.id, size: 30)
                                Text(profile.name).font(.callout).lineLimit(2)
                                Spacer()
                            }
                            .padding(8).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("speaker-review.profile.\(profile.id)")
                    }
                    if matches.isEmpty {
                        Text(profiles.isEmpty ? "Create a profile to get started." : "No matching profiles.")
                            .font(.callout).foregroundStyle(.secondary).padding(20)
                    }
                }
            }
        }
        .padding(16).frame(width: 320, height: 340)
    }
}

@MainActor
private struct AudioSpeakerReviewNameSheet: View {
    let speakerName: String
    let onSave: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var name = ""
    @State private var errorMessage: String?
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create a profile for \(speakerName)").font(.title3.weight(.semibold))
            Text("This links the new person to this speaker in this meeting.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Person’s name", text: $name).textFieldStyle(.roundedBorder)
                .focused($isFocused).onSubmit(save)
                .accessibilityIdentifier("speaker-review.new-profile-name")
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and link", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("speaker-review.create-and-link")
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        do { try onSave(trimmedName); dismiss() }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension View {
    func reviewPanel() -> some View {
        background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09)) }
    }
}
