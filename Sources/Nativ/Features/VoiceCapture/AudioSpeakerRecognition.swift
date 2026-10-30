import Combine
import Foundation
import NativServerKit

/// Maintains local voice profiles as meetings arrive. Clear matches reuse a
/// profile; uncertain voices remain available for correction in the meeting.
@MainActor
final class AudioSpeakerRecognition: ObservableObject {
    @Published private(set) var processingProfileIDs = Set<String>()
    @Published private(set) var processingRecordIDs = Set<String>()
    @Published private(set) var statusMessages: [String: String] = [:]
    @Published var errorMessage: String?
    @Published private(set) var isUpdatingMeetings = false
    @Published private(set) var libraryStatus: String?
    @Published private(set) var isMeetingUpdatePaused: Bool
    @Published private(set) var meetingProgress = MeetingProgress()

    struct MeetingProgress: Equatable {
        var total = 0
        var completed = 0
        var failed = 0
        var currentRecordID: String?
        var remaining: Int { max(0, total - completed) }
    }

    private static let checkpointPreferenceKey = "audio.speakerUpdates.selectedBatch"
    private struct BatchCheckpoint: Codable {
        let pendingIDs: [String]
        let completed: Int
        let failed: Int
    }
    private let preferences: UserDefaults?
    private var refreshTask: Task<Void, Never>?
    private var pendingMeetingIDs: [String] = []

    private let store: AudioAnalyticsStore
    private let audioURL: (AudioTranscriptionRecord) -> URL?
    private let extract: @Sendable (URL, AudioDiarization, Int) async throws -> SpeakerVoiceEmbedding
    private let prepareMeeting: @MainActor (String) async throws -> Void
    private let canProcessRecord: (String) -> Bool
    private var enrollmentGeneration: [String: UUID] = [:]
    private struct CachedVoice {
        let diarization: AudioDiarization
        let embedding: SpeakerVoiceEmbedding
    }
    // Query voices are temporary. Only the first reference for a new profile
    // is persisted; a match in another meeting stores a link, not another vector.
    private var queryVoices: [String: [Int: CachedVoice]] = [:]

    init(store: AudioAnalyticsStore, audioURL: @escaping (AudioTranscriptionRecord) -> URL?,
         extract: @escaping @Sendable (URL, AudioDiarization, Int) async throws -> SpeakerVoiceEmbedding = { _, _, _ in
             throw NativAudioAnalysisError.serverNotRunning
         },
         prepareMeeting: @escaping @MainActor (String) async throws -> Void = { _ in },
         canProcessRecord: @escaping (String) -> Bool = { _ in true },
         preferences: UserDefaults? = nil) {
        self.store = store
        self.audioURL = audioURL
        self.extract = extract
        self.prepareMeeting = prepareMeeting
        self.canProcessRecord = canProcessRecord
        self.preferences = preferences
        isMeetingUpdatePaused = false
        if let data = preferences?.data(forKey: Self.checkpointPreferenceKey),
           let checkpoint = try? JSONDecoder().decode(BatchCheckpoint.self, from: data),
           !checkpoint.pendingIDs.isEmpty {
            pendingMeetingIDs = checkpoint.pendingIDs
            meetingProgress = MeetingProgress(total: checkpoint.completed + checkpoint.pendingIDs.count,
                completed: checkpoint.completed, failed: checkpoint.failed)
            isMeetingUpdatePaused = true // Relaunch never starts work.
        }
    }

    /// An explicit selection is the only entry point for historical processing.
    /// New recordings call updateMeeting(recordID:) for their own recording only.
    func processMeetings(recordIDs: Set<String>) async {
        guard !isUpdatingMeetings, !Task.isCancelled, !recordIDs.isEmpty else { return }
        pendingMeetingIDs = store.records.filter {
            recordIDs.contains($0.id) && $0.resolvedKind == .meeting
                && canProcessRecord($0.id) && audioURL($0) != nil
        }.map(\.id)
        meetingProgress = MeetingProgress(total: pendingMeetingIDs.count)
        isMeetingUpdatePaused = false
        libraryStatus = nil
        saveBatchCheckpoint()
        await runPendingMeetings()
    }

    private func runPendingMeetings() async {
        guard !isMeetingUpdatePaused, !Task.isCancelled, refreshTask == nil, !pendingMeetingIDs.isEmpty else { return }
        isUpdatingMeetings = true
        let task = Task { await self.runMeetingUpdates() }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func pauseMeetingUpdates() {
        guard isUpdatingMeetings, !isMeetingUpdatePaused else { return }
        isMeetingUpdatePaused = true
        libraryStatus = "Pausing the current meeting…"
        refreshTask?.cancel()
    }

    func cancelMeetingUpdates() {
        refreshTask?.cancel()
    }

    func resumeMeetingUpdates() async {
        guard isMeetingUpdatePaused else { return }
        if let refreshTask { await refreshTask.value }
        isMeetingUpdatePaused = false
        await runPendingMeetings()
    }

    private func saveBatchCheckpoint() {
        guard !pendingMeetingIDs.isEmpty else {
            preferences?.removeObject(forKey: Self.checkpointPreferenceKey)
            return
        }
        let checkpoint = BatchCheckpoint(pendingIDs: pendingMeetingIDs,
            completed: meetingProgress.completed, failed: meetingProgress.failed)
        if let data = try? JSONEncoder().encode(checkpoint) {
            preferences?.set(data, forKey: Self.checkpointPreferenceKey)
        }
    }

    private func runMeetingUpdates() async {
        defer {
            refreshTask = nil
            isUpdatingMeetings = false
            saveBatchCheckpoint()
            if isMeetingUpdatePaused {
                libraryStatus = "Completed work is saved. Resume to continue the remaining meetings."
            } else if Task.isCancelled, !pendingMeetingIDs.isEmpty {
                isMeetingUpdatePaused = true
                libraryStatus = "Processing interrupted. Resume to continue the selected recordings."
            }
        }
        while !Task.isCancelled && !isMeetingUpdatePaused {
            guard let recordID = pendingMeetingIDs.first else { break }
            guard let record = store.record(withID: recordID),
                  record.resolvedKind == .meeting, canProcessRecord(recordID), audioURL(record) != nil else {
                // Deleted, unavailable, or busy meetings are no longer in this
                // batch. They can be selected again when available.
                pendingMeetingIDs.removeFirst()
                meetingProgress.currentRecordID = nil
                meetingProgress.total -= 1
                saveBatchCheckpoint()
                continue
            }
            meetingProgress.currentRecordID = recordID
            libraryStatus = "Updating speakers · \(record.displayTitle)"
            do {
                try await updateMeeting(recordID: recordID)
                try Task.checkCancellation()
            } catch is CancellationError {
                return // Keep the interrupted meeting at the front of the queue.
            } catch {
                if Task.isCancelled { return }
                meetingProgress.failed += 1
                errorMessage = error.localizedDescription
            }
            pendingMeetingIDs.removeFirst()
            meetingProgress.completed += 1
            meetingProgress.currentRecordID = nil
            saveBatchCheckpoint()
        }
        if !Task.isCancelled && !isMeetingUpdatePaused {
            libraryStatus = meetingProgress.failed == 0 ? nil
                : "\(meetingProgress.failed) \(meetingProgress.failed == 1 ? "meeting needs" : "meetings need") a retry. Select them in Process recordings to try again."
        }
    }

    func reportMeetingProgress(recordID: String, status: String) {
        statusMessages[recordID] = status
        if isUpdatingMeetings, !isMeetingUpdatePaused, meetingProgress.currentRecordID == recordID,
           let record = store.record(withID: recordID) {
            libraryStatus = "\(status) · \(record.displayTitle)"
        }
    }

    func updateMeeting(recordID: String) async throws {
        guard !processingRecordIDs.contains(recordID),
              let record = store.record(withID: recordID), record.resolvedKind == .meeting,
              let url = audioURL(record) else { return }
        processingRecordIDs.insert(recordID)
        var finished = false
        defer {
            processingRecordIDs.remove(recordID)
            queryVoices[recordID] = nil
            if !finished { statusMessages[recordID] = nil }
        }
        if record.diarization?.hasCompletedTranscription != true {
            reportMeetingProgress(recordID: recordID, status: "Diarizing and transcribing meeting…")
            try await prepareMeeting(recordID)
            try Task.checkCancellation()
        }
        guard let prepared = store.record(withID: recordID),
              prepared.audioFileName == record.audioFileName,
              var detected = prepared.diarization else { throw AudioSpeakerProfileError.recordingChanged }
        guard detected.hasCompletedTranscription else { throw AudioSpeakerProfileError.transcriptionRequired }
        reportMeetingProgress(recordID: recordID, status: "Updating speaker profiles…")
        // Migrations retain the opt-in and confirmed links. Rebuild stale
        // references before classifying new voices into a different model space.
        for profileID in store.speakerProfiles.filter(\.needsVoiceReenrollment).map(\.id) {
            guard store.profile(withID: profileID)?.needsVoiceReenrollment == true else { continue }
            do {
                try await enableVoiceMatching(profileID: profileID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unavailable old reference must not block the library.
                // Its profile keeps the visible needs-refresh state.
                errorMessage = error.localizedDescription
            }
        }
        var linked = 0, created = 0, unresolved = 0
        var extractionError: Error?
        let speakersToMatch = detected.speakerIDs
        for (index, speakerID) in speakersToMatch.enumerated() {
            try Task.checkCancellation()
            guard let current = store.record(withID: recordID)?.diarization,
                  current.hasSameSegmentation(as: detected) else { throw AudioSpeakerProfileError.recordingChanged }
            // Confirmed/corrected labels and an opted-out profile stay intact.
            if !current.speakerIDs.contains(speakerID) || current.speakerProfileIDs?[String(speakerID)] != nil { continue }
            guard (try? SpeakerVoiceEmbeddingExtractor.windows(diarization: current, speakerID: speakerID)) != nil else {
                unresolved += 1
                continue
            }
            reportMeetingProgress(recordID: recordID, status: "Matching speaker \(index + 1) of \(speakersToMatch.count)…")
            let embedding: SpeakerVoiceEmbedding
            do {
                embedding = try await voice(recordID: recordID, url: url, diarization: current, speakerID: speakerID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                extractionError = error
                unresolved += 1
                continue
            }
            try Task.checkCancellation()
            guard let latest = store.record(withID: recordID)?.diarization,
                  latest.hasSameSegmentation(as: detected),
                  latest.speakerNames?[String(speakerID)] == current.speakerNames?[String(speakerID)],
                  latest.speakerProfileIDs?[String(speakerID)] == nil else {
                throw AudioSpeakerProfileError.recordingChanged
            }
            let profiles = store.speakerProfiles
            let dismissed = Set(latest.dismissedSpeakerSuggestions?[String(speakerID)] ?? [])
            if let match = AudioSpeakerMatcher.suggestion(for: embedding, profiles: profiles,
                    excludingRecordID: recordID, dismissedProfileIDs: dismissed) {
                try store.linkSpeaker(speakerID: speakerID, recordID: recordID,
                                      profileID: match.profileID, expectedDiarization: latest)
                linked += 1
            } else if Self.hasPossibleMatch(embedding, profiles: profiles) || !dismissed.isEmpty {
                // A small margin or an explicitly rejected link is not a new
                // identity. Leave it unlinked rather than duplicating a profile.
                unresolved += 1
            } else {
                _ = try store.createVoiceProfile(embedding: embedding, speakerID: speakerID,
                                                 recordID: recordID, expectedDiarization: latest)
                created += 1
            }
            // Our own link can merge voice IDs. Accept that new baseline while
            // retaining the stale-result checks around every awaited extraction.
            detected = store.record(withID: recordID)?.diarization ?? detected
        }
        // Bound ephemeral query storage to this pass. Linked profiles supply
        // persistent references; uncertain voices can be retried explicitly.
        queryVoices[recordID] = nil
        statusMessages[recordID] = "\(linked) linked · \(created) new \(created == 1 ? "profile" : "profiles")"
            + (unresolved == 0 ? "" : " · \(unresolved) \(unresolved == 1 ? "speaker needs" : "speakers need") review")
        finished = true
        if let extractionError {
            throw extractionError
        }
    }

    private static func hasPossibleMatch(_ embedding: SpeakerVoiceEmbedding, profiles: [AudioSpeakerProfile]) -> Bool {
        profiles.filter { $0.voiceMatchingEnabled }.contains { profile in
            let scores = (profile.voiceSamples ?? []).filter { (try? $0.embedding.validate()) != nil }
                .compactMap { AudioSpeakerMatcher.cosine(embedding.vector, $0.embedding.vector) }
            return !scores.isEmpty && scores.reduce(0, +) / Double(scores.count) >= AudioSpeakerMatcher.minimumSimilarity
        }
    }

    private func voice(recordID: String, url: URL, diarization: AudioDiarization, speakerID: Int) async throws -> SpeakerVoiceEmbedding {
        if let saved = store.voiceEmbedding(recordID: recordID, speakerID: speakerID) { return saved }
        if let cached = queryVoices[recordID]?[speakerID], cached.diarization.hasSameSegmentation(as: diarization) {
            return cached.embedding
        }
        let result = try await extract(url, diarization, speakerID)
        try result.validate()
        try Task.checkCancellation()
        queryVoices[recordID, default: [:]][speakerID] = CachedVoice(diarization: diarization, embedding: result)
        return result
    }

    func enableVoiceMatching(profileID: String) async throws {
        guard !processingProfileIDs.contains(profileID) else { return }
        guard store.profile(withID: profileID) != nil else { throw AudioSpeakerProfileError.missingProfile }
        if let profile = store.profile(withID: profileID), profile.hasCurrentVoiceSample { return }
        processingProfileIDs.insert(profileID)
        let generation = UUID()
        enrollmentGeneration[profileID] = generation
        errorMessage = nil
        defer {
            processingProfileIDs.remove(profileID)
            for record in store.records(linkedToProfileID: profileID) { queryVoices[record.id] = nil }
        }
        var lastError: Error = AudioSpeakerProfileError.noVoiceSample
        var extractionAttempts = 0
        for record in store.records(linkedToProfileID: profileID) {
            guard let diarization = record.diarization, diarization.hasCompletedTranscription,
                  let url = audioURL(record) else { continue }
            let slots = diarization.speakerIDs.filter { diarization.speakerProfileIDs?[String($0)] == profileID }
            for speakerID in slots {
                guard (try? SpeakerVoiceEmbeddingExtractor.windows(diarization: diarization, speakerID: speakerID)) != nil else { continue }
                guard extractionAttempts < 3 else { break }
                extractionAttempts += 1
                do {
                    let embedding = try await voice(recordID: record.id, url: url, diarization: diarization, speakerID: speakerID)
                    try Task.checkCancellation()
                    guard enrollmentGeneration[profileID] == generation else { throw CancellationError() }
                    try store.enrollVoice(embedding, profileID: profileID, recordID: record.id,
                                          speakerID: speakerID, expectedDiarization: diarization)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch { lastError = error }
            }
        }
        errorMessage = lastError.localizedDescription
        throw lastError
    }

    func disableVoiceMatching(profileID: String) throws {
        enrollmentGeneration[profileID] = UUID()
        for record in store.records(linkedToProfileID: profileID) { queryVoices[record.id] = nil }
        try store.setVoiceMatchingEnabled(false, profileID: profileID)
    }

}
