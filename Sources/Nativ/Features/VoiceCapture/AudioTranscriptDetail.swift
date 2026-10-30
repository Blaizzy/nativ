import SwiftUI

enum AudioTranscriptSpeakerFilter: Hashable {
    case all
    case speaker(Int)
    case profile(String)
}

struct AudioTranscriptDetail: View {
    let record: AudioTranscriptionRecord
    let audioURL: URL?
    @ObservedObject var playback: AudioPlaybackState
    let onSeek: (Double) -> Void
    let onRenameSpeaker: (Int, String) -> Void
    var seekTarget: Double? = nil
    var seekRequestID: UUID? = nil
    var isVisible = true
    @Binding var speakerFilter: AudioTranscriptSpeakerFilter

    @State private var turns: [AudioDiarization.TranscriptSegment]
    @State private var followsPlayback = true
    @State private var search = ""
    @FocusState private var searchIsFocused: Bool
    @State private var pendingSourceSeek: Double?

    private struct SourceSeek: Equatable {
        let seconds: Double?
        let id: UUID?
    }

    private var sourceSeek: SourceSeek { SourceSeek(seconds: seekTarget, id: seekRequestID) }

    init(
        record: AudioTranscriptionRecord,
        audioURL: URL?,
        playback: AudioPlaybackState,
        onSeek: @escaping (Double) -> Void,
        onRenameSpeaker: @escaping (Int, String) -> Void,
        seekTarget: Double? = nil,
        seekRequestID: UUID? = nil,
        isVisible: Bool = true,
        speakerFilter: Binding<AudioTranscriptSpeakerFilter> = .constant(.all)
    ) {
        self.record = record
        self.audioURL = audioURL
        self.playback = playback
        self.onSeek = onSeek
        self.onRenameSpeaker = onRenameSpeaker
        self.seekTarget = seekTarget
        self.seekRequestID = seekRequestID
        self.isVisible = isVisible
        _speakerFilter = speakerFilter
        _turns = State(initialValue: record.diarization?.groupedByProfile.resolvedTranscriptSegments ?? [])
    }

    private var position: Double { playback.recordID == record.id ? playback.position : 0 }
    private var activeIndex: Int? {
        guard playback.recordID == record.id else { return nil }
        return turns.firstIndex { position >= $0.start && position < $0.end }
    }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleIndices: [Int] {
        turns.indices.filter { index in
            matchesSpeaker(turns[index]) && (query.isEmpty
                || turns[index].text.localizedCaseInsensitiveContains(query)
                || turns[index].speakers.contains { name($0).localizedCaseInsensitiveContains(query) })
        }
    }
    private struct SpeakerChoice: Identifiable {
        let id: AudioTranscriptSpeakerFilter
        let name: String
    }
    private var speakerChoices: [SpeakerChoice] {
        var seen: Set<AudioTranscriptSpeakerFilter> = []
        return (record.diarization?.speakerIDs ?? []).compactMap { speaker in
            let filter: AudioTranscriptSpeakerFilter
            if let profileID = record.diarization?.speakerProfileIDs?[String(speaker)] {
                filter = .profile(profileID)
            } else {
                filter = .speaker(speaker)
            }
            guard seen.insert(filter).inserted else { return nil }
            return SpeakerChoice(id: filter, name: name(speaker))
        }
    }
    private func matchesSpeaker(_ turn: AudioDiarization.TranscriptSegment) -> Bool {
        switch speakerFilter {
        case .all: true
        case .speaker(let speaker): turn.speakers.contains(speaker)
        case .profile(let profileID):
            turn.speakers.contains { record.diarization?.speakerProfileIDs?[String($0)] == profileID }
        }
    }
    private var plainParagraphs: [String] {
        record.displayTranscript.components(separatedBy: "\n\n").filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchControls
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

            Divider().opacity(0.5)

            if turns.isEmpty {
                if speakerFilter == .all {
                    plainTranscript
                } else {
                    ContentUnavailableView {
                        Label("Speaker passages unavailable", systemImage: "person.crop.circle")
                    } description: {
                        Text("This recording has no saved transcript passages to filter by speaker.")
                    } actions: {
                        Button("Show full transcript") { speakerFilter = .all }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: record.diarization) { _, value in
            turns = value?.groupedByProfile.resolvedTranscriptSegments ?? []
            if case .speaker(let speaker) = speakerFilter,
               let profileID = value?.speakerProfileIDs?[String(speaker)] {
                speakerFilter = .profile(profileID)
            }
            if speakerFilter != .all, !speakerChoices.contains(where: { $0.id == speakerFilter }) {
                speakerFilter = .all
            }
        }
        .onChange(of: isVisible) { _, visible in
            if !visible { searchIsFocused = false }
        }
    }

    private func name(_ speaker: Int) -> String {
        record.diarization?.speakerName(speaker) ?? "Speaker \(speaker + 1)"
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            if !turns.isEmpty {
                HStack(spacing: 12) {
                    Picker("Show speaker", selection: $speakerFilter) {
                        Text("All speakers").tag(AudioTranscriptSpeakerFilter.all)
                        ForEach(speakerChoices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                    .accessibilityLabel("Filter transcript by speaker")
                    .accessibilityIdentifier("recording.transcript.speaker-filter")
                    Text("\(visibleIndices.count) passages")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in transcript", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)
                    .accessibilityLabel("Find in transcript or speaker names")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear transcript search")
                }
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }

            if !turns.isEmpty {
                Toggle("Follow playback", isOn: $followsPlayback)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
                    .help("Keep the current passage in view as the recording plays")
            }
        }
    }

    private var plainTranscript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if plainParagraphs.isEmpty {
                    noMatches
                } else {
                    ForEach(Array(plainParagraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: 15))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleIndices, id: \.self) { index in
                        turnRow(turns[index], active: index == activeIndex).id(index)
                    }
                    if visibleIndices.isEmpty { noMatches }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            .onAppear {
                if isVisible, seekTarget == nil {
                    if speakerFilter != .all, let first = visibleIndices.first {
                        proxy.scrollTo(first, anchor: .top)
                    } else {
                        scrollToPassage(at: position, proxy: proxy)
                    }
                }
            }
            .task(id: sourceSeek) {
                guard let target = seekTarget else { return }
                pendingSourceSeek = target
                search = ""
                speakerFilter = .all
                // Let the unfiltered rows mount before seeking to a passage that
                // a previous search may have removed from the lazy stack.
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollToPassage(at: target, proxy: proxy)
                pendingSourceSeek = nil
            }
            .onChange(of: activeIndex) { _, index in
                guard isVisible, followsPlayback, pendingSourceSeek == nil,
                      let index, visibleIndices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onChange(of: followsPlayback) { _, follows in
                if isVisible, follows { scrollToPassage(at: position, proxy: proxy) }
            }
            .onChange(of: isVisible) { _, visible in
                if visible, followsPlayback, pendingSourceSeek == nil {
                    scrollToPassage(at: position, proxy: proxy)
                }
            }
            .onChange(of: query) { _, query in
                guard isVisible, pendingSourceSeek == nil else { return }
                if query.isEmpty {
                    if followsPlayback { scrollToPassage(at: position, proxy: proxy) }
                } else if let first = visibleIndices.first {
                    proxy.scrollTo(first, anchor: .top)
                }
            }
            .onChange(of: speakerFilter) { _, _ in
                guard isVisible, let first = visibleIndices.first else { return }
                proxy.scrollTo(first, anchor: .top)
            }
        }
    }

    @ViewBuilder private var noMatches: some View {
        if query.isEmpty {
            ContentUnavailableView("No passages for this speaker", systemImage: "person.crop.circle",
                                   description: Text("Choose another speaker or show all speakers."))
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        }
    }

    private func scrollToPassage(at time: Double, proxy: ScrollViewProxy) {
        // Source timestamps can fall in a short silence before the next turn.
        let index = turns.firstIndex { time >= $0.start && time < $0.end }
            ?? turns.firstIndex { $0.start >= time }
            ?? turns.indices.last
        guard let index, visibleIndices.contains(index) else { return }
        proxy.scrollTo(index, anchor: .center)
    }

    private func turnRow(_ turn: AudioDiarization.TranscriptSegment, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button { onSeek(turn.start) } label: {
                HStack(spacing: 5) {
                    Image(systemName: active ? "waveform" : "play.fill")
                        .font(.system(size: 9))
                        .frame(width: 11)
                    Text(AudioDiarization.timestamp(turn.start)).monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 72, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(audioURL == nil)
            .accessibilityLabel("Play segment at \(AudioDiarization.timestamp(turn.start))")
            .help("Jump to \(AudioDiarization.timestamp(turn.start)) in the recording")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Self.color(turn.speakers.first ?? 0))
                        .frame(width: 6, height: 6)
                    Text(turn.speakers.isEmpty ? "Unassigned speaker" : turn.speakers.map(name).joined(separator: " + "))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Self.color(turn.speakers.first ?? 0))
                }
                Text(turn.text)
                    .font(.system(size: 15))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if audioURL != nil { onSeek(turn.start) } }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 18)
            }
        }
    }

    static func color(_ speaker: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .indigo, .brown]
        return colors[max(0, speaker) % colors.count]
    }
}
