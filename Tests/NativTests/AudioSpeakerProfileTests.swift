import Foundation
import XCTest

@MainActor
final class AudioSpeakerProfileTests: XCTestCase {
    func testSpeakerEmbeddingCacheFollowsMainWithoutFixedWeightSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(AudioSpeakerEmbeddingModel.weightsURL(cachePath: directory.path))
        let repository = directory.appendingPathComponent("models--" + AudioSpeakerEmbeddingModel.repoID.replacingOccurrences(of: "/", with: "--"))
        let reference = repository.appendingPathComponent("refs/main")
        try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "../invalid".write(to: reference, atomically: true, encoding: .utf8)
        XCTAssertNil(AudioSpeakerEmbeddingModel.weightsURL(cachePath: directory.path))
        let revision = String(repeating: "a", count: 40)
        try revision.write(to: reference, atomically: true, encoding: .utf8)
        let weights = try XCTUnwrap(AudioSpeakerEmbeddingModel.weightsURL(cachePath: directory.path))
        XCTAssertEqual(weights, repository.appendingPathComponent("snapshots/\(revision)/model.safetensors"))
        XCTAssertFalse(AudioSpeakerEmbeddingModel.isInstalled(cachePath: directory.path))
        try FileManager.default.createDirectory(at: weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: weights)
        XCTAssertFalse(AudioSpeakerEmbeddingModel.isInstalled(cachePath: directory.path))
        try Data([1, 2, 3]).write(to: weights)
        XCTAssertTrue(AudioSpeakerEmbeddingModel.isInstalled(cachePath: directory.path))
        let nextRevision = String(repeating: "b", count: 40)
        try nextRevision.write(to: reference, atomically: true, encoding: .utf8)
        let nextWeights = try XCTUnwrap(AudioSpeakerEmbeddingModel.weightsURL(cachePath: directory.path))
        XCTAssertNotEqual(weights, nextWeights)
        XCTAssertFalse(AudioSpeakerEmbeddingModel.isInstalled(cachePath: directory.path),
                       "An old cached snapshot must not stand in for the current main snapshot")
        try FileManager.default.createDirectory(at: nextWeights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4, 5]).write(to: nextWeights)
        XCTAssertTrue(AudioSpeakerEmbeddingModel.isInstalled(cachePath: directory.path))
    }

    func testReviewCacheInvalidatesAfterProfileRenameLinkUndoAndLocalLabelChanges() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("review", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            @MainActor func reviewItem() -> AudioSpeakerReviewItem? {
                store.speakerReviewItems.first { $0.recordID == "review" && $0.speakerID == 0 }
            }
            XCTAssertEqual(reviewItem()?.reason, .noMatch)
            XCTAssertEqual(reviewItem()?.reason, .noMatch)
            store = try loadingSuggestion(.init(profileID: profile.id, similarity: 0.9), speakerID: 0, recordID: "review",
                store: store, in: directory)
            XCTAssertEqual(reviewItem()?.reason, .possibleMatch)
            XCTAssertEqual(reviewItem()?.suggestedProfileName, "Alex")

            try store.renameSpeakerProfile(id: profile.id, name: "Alex Rivera")
            XCTAssertEqual(reviewItem()?.suggestedProfileName, "Alex Rivera")
            let item = try XCTUnwrap(reviewItem())
            let undo = try store.linkSpeakerForReview(speakerID: 0, recordID: "review", profileID: profile.id,
                expectedFingerprint: item.segmentationFingerprint)
            XCTAssertNil(reviewItem())
            try store.undoSpeakerReview(undo)
            XCTAssertEqual(reviewItem()?.reason, .possibleMatch)
            XCTAssertEqual(reviewItem()?.suggestedProfileName, "Alex Rivera")

            store.updateSpeakerName("Local speaker label", speakerID: 0, for: "review")
            XCTAssertEqual(reviewItem()?.speakerName, "Local speaker label")
            try store.setVoiceMatchingEnabled(false, profileID: profile.id)
            XCTAssertEqual(reviewItem()?.reason, .noMatch)
            XCTAssertNil(reviewItem()?.suggestion)
        }
    }

    func testReviewQueueContainsUniqueUnlinkedReadySpeakersAndOnlyValidSuggestions() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("review", to: store, in: directory, recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
            var incomplete = soloDiarization()
            incomplete.transcriptSegments = []
            addRecording("incomplete", to: store, in: directory, diarization: incomplete)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            let suggestion = AudioSpeakerSuggestion(profileID: profile.id, similarity: 0.9)
            store = try loadingSuggestion(suggestion, speakerID: 0, recordID: "review",
                store: store, in: directory)
            try store.linkSpeaker(speakerID: 1, recordID: "review", profileID: profile.id)

            let items = store.speakerReviewItems
            XCTAssertEqual(Set(items.map(\.id)).count, items.count)
            XCTAssertFalse(items.contains { $0.recordID == "incomplete" })
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(item.recordID, "review")
            XCTAssertEqual(item.speakerID, 0)
            XCTAssertEqual(item.reason, .possibleMatch)
            XCTAssertEqual(item.suggestion, suggestion)
            XCTAssertEqual(item.suggestedProfileName, "Alex")
            XCTAssertEqual(item.transcriptQuote, "Hello.")
            XCTAssertEqual(item.soloSpeechDuration, 5)
            XCTAssertFalse(items.contains { $0.recordID == "review" && $0.speakerID == 1 })

            try store.dismissSpeakerSuggestion(speakerID: 0, recordID: "review")
            // Reloading a saved dismissed candidate must not surface it in the inbox again.
            store = try loadingSuggestion(suggestion, speakerID: 0, recordID: "review",
                store: store, in: directory)
            let dismissed = try XCTUnwrap(store.speakerReviewItems.first { $0.recordID == "review" })
            XCTAssertEqual(dismissed.reason, .noMatch)
            XCTAssertNil(dismissed.suggestion)
            XCTAssertNil(dismissed.suggestedProfileName)
            try store.setVoiceMatchingEnabled(false, profileID: profile.id)
            XCTAssertNil(store.speakerReviewItems.first { $0.recordID == "review" }?.suggestion)
        }
    }

    func testReviewExcerptExcludesOverlapAndNeverQuotesOutsideTheChosenClip() throws {
        let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: [
            .init(start: 0, end: 20, speaker: 0),
            .init(start: 4, end: 8, speaker: 1), .init(start: 12, end: 16, speaker: 1),
        ], transcriptSegments: [
            .init(start: 0, end: 4, speakers: [0], text: "The first solo turn."),
            .init(start: 4, end: 8, speakers: [0, 1], text: "Overlapped words."),
        ])
        let excerpt = try XCTUnwrap(AudioSpeakerReviewExcerpt.best(in: diarization, speakerID: 0))
        XCTAssertEqual(excerpt, .init(start: 0, end: 4))
        XCTAssertEqual(AudioSpeakerReviewExcerpt.soloSpeechDuration(in: diarization, speakerID: 0), 12)
        XCTAssertEqual(AudioSpeakerReviewExcerpt.transcriptQuote(in: diarization, speakerID: 0, excerpt: excerpt), "The first solo turn.")
        XCTAssertNil(AudioSpeakerReviewExcerpt.transcriptQuote(in: diarization, speakerID: 0, excerpt: .init(start: 16, end: 20)))
        XCTAssertNil(AudioSpeakerReviewExcerpt.best(in: diarization, speakerID: 1))
        try withStore { store, directory in
            let short = AudioDiarization(modelID: "model", revision: "revision", segments: [
                .init(start: 0, end: 2, speaker: 0),
            ], transcriptSegments: [.init(start: 0, end: 2, speakers: [0], text: "A short turn.")])
            addRecording("short", to: store, in: directory, diarization: short)
            let item = try XCTUnwrap(store.speakerReviewItems.first)
            XCTAssertEqual(item.reason, .insufficientSpeech)
            XCTAssertEqual(item.soloSpeechDuration, 2)
            XCTAssertEqual(item.excerpt, .init(start: 0, end: 2))
        }
    }

    func testProfileSamplesChooseDistinctSoloTurnsAndBoundPlaybackInRecordingOrder() {
        let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: [
            .init(start: 0, end: 4, speaker: 0),
            .init(start: 10, end: 35, speaker: 0),
            .init(start: 12, end: 15, speaker: 1),
            .init(start: 50, end: 59, speaker: 0),
            .init(start: 70, end: 72, speaker: 0),
        ])
        XCTAssertEqual(AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: 0), [
            .init(start: 0, end: 4), .init(start: 15, end: 25), .init(start: 50, end: 59),
        ])
        XCTAssertEqual(AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: 0, limit: 1), [
            .init(start: 15, end: 25),
        ])
        XCTAssertTrue(AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: 1).isEmpty)
        XCTAssertTrue(AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: 2).isEmpty)
        XCTAssertTrue(AudioSpeakerReviewExcerpt.samples(in: diarization, speakerID: 0, limit: 0).isEmpty)
    }

    func testReviewQueueExcludesNonMeetingsAndOrphanedReferenceSuggestions() throws {
        try withDirectory { directory in
            var meeting = fixtureRecord(id: "meeting")
            meeting.diarization?.speakerSuggestions = ["0": .init(profileID: "orphan", similarity: 0.9)]
            let orphan = voiceProfile("orphan", embedding: embedding(), recordID: "missing-reference")
            let storage = directory.appendingPathComponent("records.json")
            try JSONEncoder().encode(StorageFixture(records: [meeting], speakerProfiles: [orphan])).write(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            store.upsertTranscription(recordingURL: directory.appendingPathComponent("dictation.wav"),
                transcript: "A dictation", durationSeconds: 12, modelID: "model", applicationName: nil,
                kind: .dictation, diarization: fixtureDiarization())
            let items = store.speakerReviewItems
            XCTAssertEqual(items.count, 2)
            XCTAssertTrue(items.allSatisfy { $0.recordID == "meeting" })
            XCTAssertTrue(items.allSatisfy { $0.suggestion == nil && $0.reason == .noMatch })
        }
    }

    func testReviewUndoRestoresOnlyItsSlotAndRemovedVoiceSamplesPreservingOtherEdits() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            addRecording("other", to: store, in: directory)
            let previous = try store.createSpeakerProfile(name: "Previous")
            let selected = try store.createSpeakerProfile(name: "Selected")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: previous.id)
            try enroll(previous.id, recordID: "meeting", speakerID: 0, store: store)
            let voice = try XCTUnwrap(store.voiceEmbedding(recordID: "meeting", speakerID: 0))
            let undo = try store.linkSpeakerForReview(speakerID: 0, recordID: "meeting", profileID: selected.id)
            XCTAssertFalse(store.profile(withID: previous.id)?.voiceMatchingEnabled ?? true)
            let unrelated = try store.createSpeakerProfile(name: "Unrelated")
            try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: unrelated.id)
            store.updateSummary("A concurrent summary edit", for: "other")
            try store.renameSpeakerProfile(id: previous.id, name: "Updated previous name")

            try store.undoSpeakerReview(undo)

            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), previous.id)
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(0), "Updated previous name")
            XCTAssertEqual(store.voiceEmbedding(recordID: "meeting", speakerID: 0), voice)
            XCTAssertTrue(store.profile(withID: previous.id)?.voiceMatchingEnabled == true)
            XCTAssertEqual(store.profileID(speakerID: 1, recordID: "meeting"), unrelated.id)
            XCTAssertEqual(store.record(withID: "other")?.summary, "A concurrent summary edit")
            XCTAssertNil(store.record(withID: "meeting")?.diarization?.dismissedSpeakerSuggestions?["0"])
        }
    }

    func testReviewCreateUndoKeepsAProfileThatAcquiredAnUnrelatedMeetingLink() throws {
        for additionalLink in [false, true] {
            try withStore { store, directory in
                addRecording("meeting", to: store, in: directory)
                addRecording("other", to: store, in: directory)
                let undo = try store.createAndLinkSpeakerForReview(name: "New person", speakerID: 0, recordID: "meeting")
                if additionalLink {
                    try store.linkSpeaker(speakerID: 1, recordID: "other", profileID: undo.linkedProfileID)
                }
                try store.undoSpeakerReview(undo)
                XCTAssertNil(store.profileID(speakerID: 0, recordID: "meeting"))
                XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(0), "Speaker 1")
                XCTAssertEqual(store.profile(withID: undo.linkedProfileID) != nil, additionalLink)
                XCTAssertEqual(store.profileID(speakerID: 1, recordID: "other"), additionalLink ? undo.linkedProfileID : nil)
            }
        }
    }

    func testReviewUndoRejectsChangedSlotSegmentationOrVoiceStateWithoutPartialRestoration() throws {
        for mutation in ["slot", "segments", "voice", "save-failure"] {
            try withStore { store, directory in
                addRecording("meeting", to: store, in: directory)
                addRecording("other", to: store, in: directory)
                let previous = try store.createSpeakerProfile(name: "Previous")
                let selected = try store.createSpeakerProfile(name: "Selected")
                try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: previous.id)
                try enroll(previous.id, recordID: "meeting", speakerID: 0, store: store)
                let undo = try store.linkSpeakerForReview(speakerID: 0, recordID: "meeting", profileID: selected.id)
                switch mutation {
                case "slot": try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: nil)
                case "segments": addRecording("meeting", to: store, in: directory, diarization: fixtureDiarization(offset: 1))
                case "voice":
                    try store.linkSpeaker(speakerID: 0, recordID: "other", profileID: previous.id)
                    try enroll(previous.id, recordID: "other", speakerID: 0, store: store)
                default:
                    let storage = directory.appendingPathComponent("records.json")
                    try FileManager.default.removeItem(at: storage)
                    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
                }
                let records = store.records, profiles = store.speakerProfiles
                XCTAssertThrowsError(try store.undoSpeakerReview(undo), mutation)
                XCTAssertEqual(store.records, records, mutation)
                XCTAssertEqual(store.speakerProfiles, profiles, mutation)
            }
        }
    }

    func testReviewActionsRejectStaleCardsBeforeChangingAnyLinksOrProfiles() throws {
        for mutation in ["linked", "regenerated", "incomplete"] {
            try withStore { store, directory in
                addRecording("meeting", to: store, in: directory)
                let item = try XCTUnwrap(store.speakerReviewItems.first)
                let profile = try store.createSpeakerProfile(name: "Selected")
                switch mutation {
                case "linked": try store.linkSpeaker(speakerID: item.speakerID, recordID: item.recordID, profileID: profile.id)
                case "regenerated": addRecording("meeting", to: store, in: directory, diarization: fixtureDiarization(offset: 1))
                default:
                    var incomplete = fixtureDiarization()
                    incomplete.transcriptSegments = []
                    addRecording("meeting", to: store, in: directory, diarization: incomplete)
                }
                let records = store.records, profiles = store.speakerProfiles
                try assertNoStorageWrite(directory.appendingPathComponent("records.json")) {
                    XCTAssertThrowsError(try store.linkSpeakerForReview(speakerID: item.speakerID, recordID: item.recordID,
                        profileID: profile.id, expectedFingerprint: item.segmentationFingerprint))
                    XCTAssertThrowsError(try store.createAndLinkSpeakerForReview(name: "New person", speakerID: item.speakerID,
                        recordID: item.recordID, expectedFingerprint: item.segmentationFingerprint))
                }
                XCTAssertEqual(store.records, records, mutation)
                XCTAssertEqual(store.speakerProfiles, profiles, mutation)
            }
        }
    }

    func testLegacyArrayMigratesWithoutChangingRecordingContents() throws {
        try withDirectory { directory in
            let storage = directory.appendingPathComponent("records.json")
            let original = fixtureRecord(id: "legacy")
            try JSONEncoder().encode([original]).write(to: storage)

            let store = AudioAnalyticsStore(storageURL: storage)
            XCTAssertEqual(store.records, [original])
            XCTAssertTrue(store.speakerProfiles.isEmpty)
            let profile = try store.createSpeakerProfile(name: "Alex")

            let reloaded = AudioAnalyticsStore(storageURL: storage)
            XCTAssertEqual(reloaded.records, [original])
            XCTAssertEqual(reloaded.speakerProfiles, [profile])
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [String: Any])
            XCTAssertEqual(envelope["version"] as? Int, 1)
            XCTAssertEqual(reloaded.records.first?.audioFileName, "legacy.wav")
            XCTAssertEqual(reloaded.records.first?.summary, "A saved summary.")
        }
    }

    func testAtomicTranscriptionSaveFailurePreservesRecordsProfilesLinksAndMetrics() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            store = try loadingSuggestion(.init(profileID: profile.id, similarity: 0.9), speakerID: 0, recordID: "candidate",
                store: store, in: directory)
            let originalRecords = store.records, originalProfiles = store.speakerProfiles
            let words = store.totalWords, speed = store.averageWordsPerMinute
            let storage = directory.appendingPathComponent("records.json")
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)

            XCTAssertThrowsError(try store.saveTranscription(recordingURL: directory.appendingPathComponent("source.wav"),
                transcript: "Replacement text that must never be published.", durationSeconds: 60,
                modelID: "new-model", applicationName: "New app", title: "Replacement title",
                summary: "Replacement summary", diarization: fixtureDiarization(offset: 0.5)))

            XCTAssertEqual(store.records, originalRecords)
            XCTAssertEqual(store.speakerProfiles, originalProfiles)
            XCTAssertEqual(store.totalWords, words)
            XCTAssertEqual(store.averageWordsPerMinute, speed)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), profile.id)
            XCTAssertEqual(store.voiceEmbedding(recordID: "source", speakerID: 0), embedding())
            // Legacy callers keep their nonthrowing API without publishing an
            // unsaved result or partially invalidating voice enrollments.
            store.upsertTranscription(recordingURL: directory.appendingPathComponent("source.wav"),
                transcript: "Also not saved", durationSeconds: nil, modelID: nil, applicationName: nil,
                diarization: fixtureDiarization(offset: 1))
            XCTAssertEqual(store.records, originalRecords)
            XCTAssertEqual(store.speakerProfiles, originalProfiles)
        }
    }

    func testAtomicTranscriptionSavePreservesIdentityThenInvalidatesChangedDiarizationAfterSaving() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            store = try loadingSuggestion(.init(profileID: profile.id, similarity: 0.9), speakerID: 0, recordID: "candidate",
                store: store, in: directory)
            let original = try XCTUnwrap(store.record(withID: "source"))
            let enrolled = try XCTUnwrap(store.profile(withID: profile.id))
            let savedAt = original.updatedAt.addingTimeInterval(120)
            try store.saveTranscription(recordingURL: directory.appendingPathComponent("source.wav"),
                transcript: "A corrected saved transcript.", durationSeconds: nil, modelID: nil, applicationName: nil,
                diarization: fixtureDiarization(), updatedAt: savedAt)

            let corrected = try XCTUnwrap(store.record(withID: "source"))
            XCTAssertEqual(corrected.transcript, "A corrected saved transcript.")
            XCTAssertEqual(corrected.updatedAt, savedAt)
            XCTAssertEqual(corrected.recordedAt, original.recordedAt)
            XCTAssertEqual(corrected.summary, original.summary)
            XCTAssertEqual(corrected.title, original.title)
            XCTAssertEqual(corrected.audioFileName, original.audioFileName)
            XCTAssertEqual(store.profile(withID: profile.id), enrolled)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), profile.id)
            var reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            XCTAssertEqual(reloaded.record(withID: "source"), corrected)
            XCTAssertEqual(reloaded.profile(withID: profile.id), enrolled)

            try store.saveTranscription(recordingURL: directory.appendingPathComponent("source.wav"),
                transcript: "New diarization transcript.", durationSeconds: 13, modelID: "new-speech-model",
                applicationName: "Other recorder", title: "New title", summary: "New summary",
                diarization: fixtureDiarization(offset: 0.5), recordedAt: savedAt, updatedAt: savedAt)
            reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            let changed = try XCTUnwrap(reloaded.record(withID: "source"))
            XCTAssertEqual(changed.transcript, "New diarization transcript.")
            XCTAssertEqual(changed.recordedAt, original.recordedAt)
            XCTAssertEqual(changed.durationSeconds, 13)
            XCTAssertEqual(changed.modelID, "new-speech-model")
            XCTAssertEqual(changed.applicationName, "Other recorder")
            XCTAssertEqual(changed.title, "New title")
            XCTAssertEqual(changed.summary, "New summary")
            XCTAssertNil(reloaded.profileID(speakerID: 0, recordID: "source"))
            XCTAssertFalse(reloaded.profile(withID: profile.id)?.voiceMatchingEnabled ?? true)
            XCTAssertNil(reloaded.voiceEmbedding(recordID: "source", speakerID: 0))
            XCTAssertNil(reloaded.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"])
            XCTAssertEqual(store.record(withID: "source"), changed)
        }
    }

    func testDuplicateEnrollmentAndUnchangedSpeakerChangesDoNotRewriteStorage() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            let suggestion = AudioSpeakerSuggestion(profileID: profile.id, similarity: 0.9)
            store = try loadingSuggestion(suggestion, speakerID: 0, recordID: "candidate",
                store: store, in: directory)
            let enrolled = try XCTUnwrap(store.profile(withID: profile.id))
            let storage = directory.appendingPathComponent("records.json")

            try assertNoStorageWrite(storage) {
                try store.enrollVoice(embedding(similarity: 0.8), profileID: profile.id, recordID: "source",
                    speakerID: 0, expectedDiarization: XCTUnwrap(store.record(withID: "source")?.diarization))
                try store.renameSpeakerProfile(id: profile.id, name: "  Alex  ")
                try store.setVoiceMatchingEnabled(true, profileID: profile.id)
            }
            XCTAssertEqual(store.profile(withID: profile.id), enrolled)
            XCTAssertEqual(store.voiceEmbedding(recordID: "source", speakerID: 0), embedding())
            XCTAssertEqual(store.voiceEmbedding(recordID: "source", speakerID: 0, profileID: profile.id), embedding())
            XCTAssertNil(store.voiceEmbedding(recordID: "source", speakerID: 0, profileID: "other"))
            XCTAssertNil(store.voiceEmbedding(recordID: "candidate", speakerID: 0))

            try store.setVoiceMatchingEnabled(false, profileID: profile.id)
            XCTAssertNil(store.voiceEmbedding(recordID: "source", speakerID: 0))
            try assertNoStorageWrite(storage) { try store.setVoiceMatchingEnabled(false, profileID: profile.id) }
        }
    }

    func testAtomicVoiceProfileCreationNamesAndLinksOnceWithoutDuplicatingEmbeddings() throws {
        try withStore { store, directory in
            for id in ["first", "second", "known"] { addRecording(id, to: store, in: directory) }
            let firstExpected = try XCTUnwrap(store.record(withID: "first")?.diarization)
            let first = try store.createVoiceProfile(embedding: embedding(), speakerID: 0,
                recordID: "first", expectedDiarization: firstExpected)
            XCTAssertEqual(first.name, "Unnamed speaker 1")
            XCTAssertTrue(first.voiceMatchingEnabled)
            XCTAssertEqual(first.voiceSamples?.count, 1)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "first"), first.id)
            try assertNoStorageWrite(directory.appendingPathComponent("records.json")) {
                XCTAssertThrowsError(try store.createVoiceProfile(embedding: embedding(), speakerID: 0,
                    recordID: "first", expectedDiarization: firstExpected))
            }
            let second = try store.createVoiceProfile(embedding: embedding(similarity: 0.2), speakerID: 0,
                recordID: "second", expectedDiarization: XCTUnwrap(store.record(withID: "second")?.diarization))
            XCTAssertEqual(second.name, "Unnamed speaker 2")
            let known = try XCTUnwrap(store.record(withID: "known")?.diarization)
            try store.linkSpeaker(speakerID: 0, recordID: "known", profileID: first.id, expectedDiarization: known)
            XCTAssertEqual(store.profile(withID: first.id), first)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "known"), first.id)
            XCTAssertEqual(store.speakerProfiles.count, 2)
            let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            XCTAssertEqual(reloaded.profile(withID: first.id)?.voiceSamples?.count, 1)
            XCTAssertEqual(reloaded.profileID(speakerID: 0, recordID: "known"), first.id)
        }
    }

    func testAutomaticVoiceProfilePreservesManualNameAndLinkRejectsStaleIdentity() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            store.updateSpeakerName("Alex", speakerID: 0, for: "meeting")
            let named = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            let profile = try store.createVoiceProfile(embedding: embedding(), speakerID: 0,
                recordID: "meeting", expectedDiarization: named)
            XCTAssertEqual(profile.name, "Alex")
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(0), "Alex")

            let other = try store.createSpeakerProfile(name: "Other")
            XCTAssertThrowsError(try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: other.id,
                expectedDiarization: named))
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), profile.id)
            let beforeNameEdit = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            store.updateSpeakerName("Manually edited", speakerID: 1, for: "meeting")
            XCTAssertThrowsError(try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: other.id,
                expectedDiarization: beforeNameEdit))
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(1), "Manually edited")
        }
    }

    func testVoiceProfileCreationWriteFailureLeavesNoPartialProfileEmbeddingOrLink() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let expected = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            let before = store.records
            let storage = directory.appendingPathComponent("records.json")
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.createVoiceProfile(embedding: embedding(), speakerID: 0,
                recordID: "meeting", expectedDiarization: expected))
            XCTAssertEqual(store.records, before)
            XCTAssertTrue(store.speakerProfiles.isEmpty)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "meeting"))
        }
    }

    func testPauseCancelsActiveVoiceKeepsCompletedProgressAndResumesOnlyRemainingMeetings() async throws {
        try await withAsyncStore { store, directory in
            addRecording("first", to: store, in: directory, diarization: soloDiarization(), recordedAt: Date(timeIntervalSince1970: 200))
            addRecording("second", to: store, in: directory, diarization: soloDiarization(), recordedAt: Date(timeIntervalSince1970: 100))
            let gate = SpeakerTestGate<SpeakerVoiceEmbedding>(), log = SpeakerExtractionTestLog(), result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { url, _, _ in
                let id = url.deletingPathExtension().lastPathComponent
                await log.record(id)
                let calls = await log.recordIDs
                if id == "second", calls.filter({ $0 == id }).count == 1 {
                    let value = await gate.extract()
                    if Task.isCancelled { await log.record("cancelled") }
                    return value
                }
                return result
            })
            let task = Task { await recognition.processMeetings(recordIDs: Set(store.records.map(\.id))) }
            await gate.waitUntilStarted()
            XCTAssertEqual(recognition.meetingProgress.total, 2)
            XCTAssertEqual(recognition.meetingProgress.completed, 1)
            XCTAssertEqual(recognition.meetingProgress.remaining, 1)
            XCTAssertEqual(recognition.meetingProgress.currentRecordID, "second")
            let firstProfile = try XCTUnwrap(store.profileID(speakerID: 0, recordID: "first"))

            recognition.pauseMeetingUpdates()
            store.refreshSpeakerDirectory() // View changes cannot restart it.
            await gate.release(result)
            await task.value
            XCTAssertTrue(recognition.isMeetingUpdatePaused)
            XCTAssertFalse(recognition.isUpdatingMeetings)
            XCTAssertTrue(recognition.processingRecordIDs.isEmpty)
            XCTAssertEqual(recognition.meetingProgress.completed, 1)
            XCTAssertEqual(recognition.meetingProgress.failed, 0)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "second"))
            let pausedCalls = await log.recordIDs
            XCTAssertEqual(pausedCalls, ["first", "second", "cancelled"])

            addRecording("new-meeting", to: store, in: directory, diarization: soloDiarization())
            try await recognition.updateMeeting(recordID: "new-meeting")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "new-meeting"), firstProfile)
            XCTAssertTrue(recognition.isMeetingUpdatePaused)
            XCTAssertEqual(recognition.meetingProgress.remaining, 1)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "second"))

            await recognition.resumeMeetingUpdates()
            XCTAssertFalse(recognition.isMeetingUpdatePaused)
            XCTAssertFalse(recognition.isUpdatingMeetings)
            XCTAssertEqual(recognition.meetingProgress.completed, 2)
            XCTAssertEqual(recognition.meetingProgress.remaining, 0)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "second"), firstProfile)
            XCTAssertEqual(store.speakerProfiles.count, 1)
            let resumedCalls = await log.recordIDs
            XCTAssertEqual(resumedCalls, ["first", "second", "cancelled", "new-meeting", "second"])
        }
    }

    func testPauseDuringPreparationPersistsAcrossCoordinatorRecreationUntilExplicitResume() async throws {
        try await withAsyncStore { _, directory in
            let suite = "speaker-pause-test-\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            var record = fixtureRecord(id: "meeting")
            record.diarization = nil
            let storage = directory.appendingPathComponent("records.json")
            try JSONEncoder().encode([record]).write(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let gate = SpeakerTestGate<AudioDiarization>(), timing = soloDiarization(), result = embedding()
            let originalBytes = try Data(contentsOf: storage)
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { _, _, _ in XCTFail("Paused preparation must not extract"); return result }, prepareMeeting: { _ in
                _ = await gate.extract()
                try Task.checkCancellation()
                XCTFail("Paused preparation must not save")
            }, preferences: preferences)
            let task = Task { await recognition.processMeetings(recordIDs: Set(store.records.map(\.id))) }
            await gate.waitUntilStarted()
            recognition.pauseMeetingUpdates()
            await gate.release(timing)
            await task.value
            XCTAssertEqual(recognition.meetingProgress.completed, 0)
            XCTAssertEqual(recognition.meetingProgress.remaining, 1)
            XCTAssertEqual(try Data(contentsOf: storage), originalBytes)

            addRecording("unselected", to: store, in: directory, diarization: soloDiarization())
            let bytesBeforeRelaunch = try Data(contentsOf: storage)
            let restarted = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { _, _, _ in result }, prepareMeeting: { recordID in
                try store.saveTranscription(recordingURL: directory.appendingPathComponent("\(recordID).wav"),
                    transcript: "Hello.", durationSeconds: 5, modelID: "speech-model", applicationName: nil,
                    diarization: timing)
            }, preferences: preferences)
            XCTAssertTrue(restarted.isMeetingUpdatePaused)
            store.refreshSpeakerDirectory()
            XCTAssertFalse(restarted.isUpdatingMeetings)
            XCTAssertEqual(try Data(contentsOf: storage), bytesBeforeRelaunch)
            await restarted.resumeMeetingUpdates()
            XCTAssertFalse(restarted.isMeetingUpdatePaused)
            XCTAssertEqual(restarted.meetingProgress.completed, 1)
            XCTAssertEqual(restarted.meetingProgress.remaining, 0)
            XCTAssertEqual(store.speakerProfiles.count, 1)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "unselected"))
            let finished = AudioSpeakerRecognition(store: store, audioURL: { _ in nil }, preferences: preferences)
            XCTAssertFalse(finished.isUpdatingMeetings)
            XCTAssertFalse(finished.isMeetingUpdatePaused)
            XCTAssertEqual(finished.meetingProgress.total, 0)
        }
    }

    func testCallerCancellationLeavesSelectedBatchPausedUntilExplicitResume() async throws {
        try await withAsyncStore { store, directory in
            addRecording("meeting", to: store, in: directory, diarization: soloDiarization())
            let gate = SpeakerTestGate<SpeakerVoiceEmbedding>(), log = SpeakerExtractionTestLog(), result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { _, _, _ in
                await log.record("extract")
                let calls = await log.recordIDs
                return calls.count == 1 ? await gate.extract() : result
            })
            let task = Task { await recognition.processMeetings(recordIDs: Set(store.records.map(\.id))) }
            await gate.waitUntilStarted()
            task.cancel()
            await gate.release(result)
            await task.value
            XCTAssertFalse(recognition.isUpdatingMeetings)
            XCTAssertTrue(recognition.isMeetingUpdatePaused)
            XCTAssertEqual(recognition.meetingProgress.completed, 0)
            XCTAssertTrue(store.speakerProfiles.isEmpty)
            await recognition.resumeMeetingUpdates()
            XCTAssertEqual(recognition.meetingProgress.total, 1)
            XCTAssertEqual(recognition.meetingProgress.completed, 1)
            XCTAssertEqual(store.speakerProfiles.count, 1)
        }
    }

    func testHistoricalProcessingRequiresExplicitSelectionAndRefreshDoesNoModelWork() async throws {
        try await withAsyncStore { store, directory in
            for id in ["selected", "not-selected"] {
                addRecording(id, to: store, in: directory, diarization: soloDiarization())
            }
            let log = SpeakerExtractionTestLog(), result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.deletingPathExtension().lastPathComponent)
                return result
            })
            let storage = directory.appendingPathComponent("records.json")
            try assertNoStorageWrite(storage) { store.refreshSpeakerDirectory() }
            let initialCalls = await log.recordIDs
            XCTAssertTrue(initialCalls.isEmpty)
            XCTAssertFalse(recognition.isUpdatingMeetings)
            XCTAssertEqual(recognition.meetingProgress.total, 0)
            await recognition.processMeetings(recordIDs: ["selected"])
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["selected"])
            XCTAssertEqual(recognition.meetingProgress.completed, 1)
            XCTAssertNotNil(store.profileID(speakerID: 0, recordID: "selected"))
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "not-selected"))
        }
    }

    func testProgressCountsFailuresAndExcludesUnavailableMeetings() async throws {
        try await withAsyncStore { store, directory in
            for id in ["ready", "failed", "missing", "busy"] {
                addRecording(id, to: store, in: directory, diarization: soloDiarization())
            }
            let result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                $0.id == "missing" ? nil : directory.appendingPathComponent("\($0.id).wav")
            }, extract: { url, _, _ in
                if url.deletingPathExtension().lastPathComponent == "failed" { throw SpeakerTestError.extractionFailed }
                return result
            }, canProcessRecord: { $0 != "busy" })
            await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))
            XCTAssertEqual(recognition.meetingProgress.total, 2)
            XCTAssertEqual(recognition.meetingProgress.completed, 2)
            XCTAssertEqual(recognition.meetingProgress.failed, 1)
            XCTAssertEqual(recognition.meetingProgress.remaining, 0)
            XCTAssertNil(recognition.meetingProgress.currentRecordID)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "failed"))
            XCTAssertTrue(recognition.libraryStatus?.contains("1 meeting needs a retry") == true)
        }
    }

    func testMeetingRefreshPreparesDiarizationAndTranscriptionBeforeMatchingThenReusesIdentity() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            var original = fixtureRecord(id: "past")
            original.diarization = nil
            try JSONEncoder().encode([original]).write(to: storage)
            let audio = directory.appendingPathComponent("past.wav")
            let bytes = Data("saved meeting audio".utf8)
            try bytes.write(to: audio)
            let store = AudioAnalyticsStore(storageURL: storage)
            let log = SpeakerExtractionTestLog()
            let result = embedding(), timing = soloDiarization()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record("extract:\(url.deletingPathExtension().lastPathComponent)")
                return result
            }, prepareMeeting: { recordID in
                await log.record("diarize:\(recordID)")
                await log.record("transcribe:\(recordID)")
                var completed = timing
                completed.transcriptSegments = [.init(start: 0, end: 5, speakers: [0], text: "Fresh transcription.")]
                try store.saveTranscription(recordingURL: directory.appendingPathComponent("\(recordID).wav"),
                    transcript: "Fresh transcription.", durationSeconds: original.durationSeconds,
                    modelID: original.modelID, applicationName: original.applicationName,
                    diarization: completed, updatedAt: original.updatedAt.addingTimeInterval(60))
                await log.record("saved:\(recordID)")
            })

            await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))

            let profile = try XCTUnwrap(store.speakerProfiles.first)
            XCTAssertEqual(store.speakerProfiles.count, 1)
            XCTAssertEqual(profile.voiceSamples?.map(\.recordID), ["past"])
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "past"), profile.id)
            let updated = try XCTUnwrap(store.record(withID: "past"))
            XCTAssertEqual(updated.transcript, "Fresh transcription.")
            XCTAssertTrue(updated.displayTranscript.contains("Fresh transcription."))
            XCTAssertTrue(updated.diarization?.hasCompletedTranscription == true)
            XCTAssertEqual(updated.summary, original.summary)
            XCTAssertEqual(updated.title, original.title)
            XCTAssertEqual(updated.audioFileName, original.audioFileName)
            XCTAssertEqual(updated.recordedAt, original.recordedAt)
            XCTAssertEqual(updated.updatedAt, original.updatedAt.addingTimeInterval(60))
            XCTAssertEqual(try Data(contentsOf: audio), bytes)
            XCTAssertNil(recognition.errorMessage)

            addRecording("new", to: store, in: directory, diarization: timing,
                recordedAt: original.recordedAt.addingTimeInterval(60))
            await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "new"), profile.id)
            XCTAssertEqual(store.speakerProfiles, [profile])
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["diarize:past", "transcribe:past", "saved:past", "extract:past", "extract:new"])

            try await assertNoStorageWriteAsync(storage) { await recognition.processMeetings(recordIDs: Set(store.records.map(\.id))) }
            let repeatedCalls = await log.recordIDs
            XCTAssertEqual(repeatedCalls, calls)
            let restarted = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record("unexpected:\(url.lastPathComponent)")
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })
            try await assertNoStorageWriteAsync(storage) { await restarted.processMeetings(recordIDs: Set(store.records.map(\.id))) }
            let restartedCalls = await log.recordIDs
            XCTAssertEqual(restartedCalls, calls)
        }
    }

    func testDiarizationOnlyMeetingCompletesTranscriptionBeforeVoiceExtraction() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            var original = fixtureRecord(id: "meeting")
            original.diarization = AudioDiarization(modelID: "diarization-model", revision: "revision",
                segments: [.init(start: 0, end: 5, speaker: 0)])
            try JSONEncoder().encode([original]).write(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let log = SpeakerExtractionTestLog(), result = embedding()
            var completed = soloDiarization()
            completed.transcriptSegments = [.init(start: 0, end: 5, speakers: [0], text: "Prepared transcript.")]
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { _, _, _ in
                await log.record("extract")
                return result
            }, prepareMeeting: { recordID in
                await log.record("prepare")
                try store.saveTranscription(recordingURL: directory.appendingPathComponent("\(recordID).wav"),
                    transcript: "Prepared transcript.", durationSeconds: 5, modelID: "speech-model",
                    applicationName: nil, diarization: completed)
                await log.record("saved")
            })

            try await recognition.updateMeeting(recordID: "meeting")

            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["prepare", "saved", "extract"])
            XCTAssertEqual(store.record(withID: "meeting")?.transcript, "Prepared transcript.")
            XCTAssertTrue(store.record(withID: "meeting")?.diarization?.hasCompletedTranscription == true)
            XCTAssertEqual(store.speakerProfiles.count, 1)
        }
    }

    func testFailedOrIncompleteMeetingPreparationNeverExtractsOrCreatesProfiles() async throws {
        for preparationFails in [false, true] {
            try await withAsyncStore { _, directory in
                let storage = directory.appendingPathComponent("records.json")
                var original = fixtureRecord(id: "meeting")
                original.diarization = AudioDiarization(modelID: "diarization-model", revision: "revision",
                    segments: [.init(start: 0, end: 5, speaker: 0)])
                try JSONEncoder().encode([original]).write(to: storage)
                let store = AudioAnalyticsStore(storageURL: storage)
                let result = embedding(), log = SpeakerExtractionTestLog()
                let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                    directory.appendingPathComponent("\(record.id).wav")
                }, extract: { _, _, _ in
                    await log.record("unexpected extraction")
                    return result
                }, prepareMeeting: { _ in
                    await log.record("prepare")
                    if preparationFails { throw SpeakerTestError.extractionFailed }
                })

                try await assertNoStorageWriteAsync(storage) {
                    do {
                        try await recognition.updateMeeting(recordID: "meeting")
                        XCTFail("Incomplete preparation must not continue into voice matching")
                    } catch SpeakerTestError.extractionFailed {
                        XCTAssertTrue(preparationFails)
                    } catch AudioSpeakerProfileError.transcriptionRequired {
                        XCTAssertFalse(preparationFails)
                    }
                }

                let calls = await log.recordIDs
                XCTAssertEqual(calls, ["prepare"])
                XCTAssertEqual(store.record(withID: "meeting"), original)
                XCTAssertTrue(store.speakerProfiles.isEmpty)
                XCTAssertTrue(recognition.processingRecordIDs.isEmpty)
            }
        }
    }

    func testEmptyTranscriptMarkersDoNotCountAsCompletedMeetingTranscription() {
        var diarization = soloDiarization()
        XCTAssertTrue(diarization.hasCompletedTranscription)
        diarization.transcriptSegments = []
        XCTAssertFalse(diarization.hasCompletedTranscription)
        diarization.transcriptSegments = [.init(start: 0, end: 5, speakers: [0], text: " \n\t ")]
        XCTAssertFalse(diarization.hasCompletedTranscription)
        diarization.speakerTranscript = " \n\t "
        XCTAssertFalse(diarization.hasCompletedTranscription)
        diarization.speakerTranscript = "[00:00] Speaker 1: Saved legacy transcription."
        XCTAssertTrue(diarization.hasCompletedTranscription)
    }

    func testAmbiguousAutomaticMatchLeavesSpeakerUnlinkedWithoutCreatingDuplicateProfile() async throws {
        try await withAsyncStore { store, directory in
            for id in ["source-a", "source-b", "candidate"] {
                addRecording(id, to: store, in: directory, diarization: soloDiarization())
            }
            for (id, score) in [("source-a", 0.90), ("source-b", 0.82)] {
                try store.createVoiceProfile(embedding: embedding(similarity: score), speakerID: 0,
                    recordID: id, expectedDiarization: XCTUnwrap(store.record(withID: id)?.diarization))
            }
            let result = embedding()
            let log = SpeakerExtractionTestLog()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.deletingPathExtension().lastPathComponent)
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })

            try await assertNoStorageWriteAsync(directory.appendingPathComponent("records.json")) {
                try await recognition.updateMeeting(recordID: "candidate")
                store.refreshSpeakerDirectory()
            }

            XCTAssertEqual(store.speakerProfiles.count, 2)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "candidate"))
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions)
            XCTAssertTrue(recognition.statusMessages["candidate"]?.contains("needs review") == true)
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["candidate"])
        }
    }

    func testAutomaticRefreshHonorsCorrectedManualIdentityWithoutExtractingAgain() async throws {
        try await withAsyncStore { store, directory in
            addRecording("meeting", to: store, in: directory, diarization: soloDiarization())
            let first = try store.createVoiceProfile(embedding: embedding(), speakerID: 0, recordID: "meeting",
                expectedDiarization: XCTUnwrap(store.record(withID: "meeting")?.diarization))
            let corrected = try store.createSpeakerProfile(name: "Correct person")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: corrected.id)
            let result = embedding()
            let log = SpeakerExtractionTestLog()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.lastPathComponent)
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })

            try await assertNoStorageWriteAsync(directory.appendingPathComponent("records.json")) {
                await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))
            }

            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), corrected.id)
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(0), "Correct person")
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.dismissedSpeakerSuggestions?["0"], [first.id])
            XCTAssertFalse(store.profile(withID: corrected.id)?.voiceMatchingEnabled ?? true)
            let calls = await log.recordIDs
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testAutomaticRefreshDoesNotRestoreManuallyUnlinkedOrDeletedProfiles() async throws {
        for delete in [false, true] {
            try await withAsyncStore { store, directory in
                addRecording("meeting", to: store, in: directory, diarization: soloDiarization())
                let profile = try store.createVoiceProfile(embedding: embedding(), speakerID: 0, recordID: "meeting",
                    expectedDiarization: XCTUnwrap(store.record(withID: "meeting")?.diarization))
                if delete { try store.deleteSpeakerProfile(id: profile.id) }
                else { try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: nil) }
                let result = embedding()
                let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                    directory.appendingPathComponent("\(record.id).wav")
                }, extract: { _, _, _ in result }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })

                try await assertNoStorageWriteAsync(directory.appendingPathComponent("records.json")) {
                    await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))
                }

                XCTAssertNil(store.profileID(speakerID: 0, recordID: "meeting"))
                XCTAssertEqual(store.speakerProfiles.count, delete ? 0 : 1)
                XCTAssertEqual(store.record(withID: "meeting")?.diarization?.dismissedSpeakerSuggestions?["0"], [profile.id])
                let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
                XCTAssertEqual(reloaded.record(withID: "meeting")?.diarization?.dismissedSpeakerSuggestions?["0"], [profile.id])
            }
        }
    }

    func testCancellationOrDeletionDuringAutomaticAnalysisCannotCreateProfilesOrResurrectRecording() async throws {
        for stage in ["prepare", "extract"] {
            for cancel in [false, true] {
                try await withAsyncStore { _, directory in
                    let storage = directory.appendingPathComponent("records.json")
                    var record = fixtureRecord(id: "meeting")
                    record.diarization = stage == "prepare" ? nil : soloDiarization()
                    try JSONEncoder().encode([record]).write(to: storage)
                    let store = AudioAnalyticsStore(storageURL: storage)
                    let voiceGate = SpeakerTestGate<SpeakerVoiceEmbedding>(), timingGate = SpeakerTestGate<AudioDiarization>()
                    let result = embedding(), timing = soloDiarization()
                    let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                        directory.appendingPathComponent("\(record.id).wav")
                    }, extract: { _, _, _ in
                        stage == "extract" ? await voiceGate.extract() : result
                    }, prepareMeeting: { _ in
                        _ = await timingGate.extract()
                        // No model result was saved; the coordinator must still
                        // check cancellation/deletion and never extract a voice.
                    })
                    let task = Task { try await recognition.updateMeeting(recordID: "meeting") }
                    if stage == "prepare" { await timingGate.waitUntilStarted() }
                    else { await voiceGate.waitUntilStarted() }
                    if cancel { task.cancel() }
                    else { store.removeRecord(withID: "meeting") }
                    if stage == "prepare" { await timingGate.release(timing) }
                    else { await voiceGate.release(result) }
                    do {
                        try await task.value
                        XCTFail("Interrupted automatic analysis must be rejected")
                    } catch is CancellationError {
                        XCTAssertTrue(cancel)
                    } catch AudioSpeakerProfileError.recordingChanged {
                        XCTAssertFalse(cancel)
                    }

                    XCTAssertTrue(store.speakerProfiles.isEmpty)
                    XCTAssertEqual(store.record(withID: "meeting"), cancel ? record : nil)
                    XCTAssertTrue(recognition.processingRecordIDs.isEmpty)
                    let reloaded = AudioAnalyticsStore(storageURL: storage)
                    XCTAssertTrue(reloaded.speakerProfiles.isEmpty)
                    XCTAssertEqual(reloaded.record(withID: "meeting"), cancel ? record : nil)
                }
            }
        }
    }

    func testManualLinkWhileAutomaticEmbeddingIsPendingWins() async throws {
        try await withAsyncStore { store, directory in
            addRecording("meeting", to: store, in: directory, diarization: soloDiarization())
            let profile = try store.createSpeakerProfile(name: "Chosen person")
            let gate = SpeakerTestGate<SpeakerVoiceEmbedding>()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { _, _, _ in await gate.extract() }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })
            let task = Task { try await recognition.updateMeeting(recordID: "meeting") }
            await gate.waitUntilStarted()
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            await gate.release(embedding())
            do {
                try await task.value
                XCTFail("The stale automatic result must not overwrite a manual link")
            } catch AudioSpeakerProfileError.recordingChanged {}
            XCTAssertEqual(store.speakerProfiles, [profile])
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), profile.id)
            XCTAssertNil(store.profile(withID: profile.id)?.voiceSamples)
        }
    }

    func testUnavailableStaleVoiceReferenceDoesNotBlockAutomaticProfilesForNewMeeting() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            try writeLegacyVoiceStorage(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let result = embedding()
            let log = SpeakerExtractionTestLog()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                record.id == "source" ? nil : directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.deletingPathExtension().lastPathComponent)
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })

            try await recognition.updateMeeting(recordID: "candidate")

            let newProfileID = try XCTUnwrap(store.profileID(speakerID: 0, recordID: "candidate"))
            XCTAssertNotEqual(newProfileID, "alex")
            XCTAssertEqual(store.profile(withID: newProfileID)?.voiceSamples?.map(\.embedding), [result])
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
            XCTAssertTrue(store.profile(withID: "alex")?.needsVoiceReenrollment == true)
            XCTAssertNil(store.profile(withID: "alex")?.voiceSamples)
            XCTAssertEqual(store.speakerProfiles.count, 2)
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["candidate", "candidate"])
            XCTAssertTrue(recognition.processingProfileIDs.isEmpty)
            XCTAssertTrue(recognition.processingRecordIDs.isEmpty)
        }
    }

    func testSpeakerExtractionFailureKeepsOtherProfilesAndRetriesOnlyUnresolvedSpeaker() async throws {
        try await withAsyncStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let original = try XCTUnwrap(store.record(withID: "meeting"))
            let audio = directory.appendingPathComponent("meeting.wav")
            let audioBytes = Data("untouched source audio".utf8)
            try audioBytes.write(to: audio)
            let result = embedding()
            let log = SpeakerExtractionTestLog()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { _, _, speakerID in
                await log.record("speaker:\(speakerID)")
                if speakerID == 0 { throw SpeakerTestError.extractionFailed }
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })

            await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))

            XCTAssertNil(store.profileID(speakerID: 0, recordID: "meeting"))
            let profileID = try XCTUnwrap(store.profileID(speakerID: 1, recordID: "meeting"))
            XCTAssertEqual(store.speakerProfiles.count, 1)
            XCTAssertEqual(store.profile(withID: profileID)?.voiceSamples?.map(\.speakerID), [1])
            XCTAssertEqual(recognition.errorMessage, SpeakerTestError.extractionFailed.localizedDescription)
            XCTAssertTrue(recognition.libraryStatus?.contains("Process recordings") == true)
            XCTAssertTrue(recognition.statusMessages["meeting"]?.contains("1 new profile") == true)
            assertRecordingContent(try XCTUnwrap(store.record(withID: "meeting")), equals: original)
            XCTAssertEqual(try Data(contentsOf: audio), audioBytes)

            try await assertNoStorageWriteAsync(directory.appendingPathComponent("records.json")) {
                await recognition.processMeetings(recordIDs: Set(store.records.map(\.id)))
            }
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["speaker:0", "speaker:1", "speaker:0"])
            XCTAssertEqual(store.speakerProfiles.count, 1)
            XCTAssertEqual(store.profileID(speakerID: 1, recordID: "meeting"), profileID)
            XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
        }
    }

    func testOptingOutLaterStaleProfileDuringAnotherEnrollmentIsNotReenabled() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            let timing = soloDiarization()
            var first = fixtureRecord(id: "first-source"), second = fixtureRecord(id: "second-source")
            var candidate = fixtureRecord(id: "candidate")
            first.diarization = timing
            first.diarization?.speakerProfileIDs = ["0": "first"]
            first.diarization?.speakerNames = ["0": "first"]
            second.diarization = timing
            second.diarization?.speakerProfileIDs = ["0": "second"]
            second.diarization?.speakerNames = ["0": "second"]
            candidate.diarization = timing
            let profiles = [
                voiceProfile("first", embedding: legacyEmbedding(), recordID: "first-source"),
                voiceProfile("second", embedding: legacyEmbedding(), recordID: "second-source"),
            ]
            try JSONEncoder().encode(StorageFixture(records: [first, second, candidate], speakerProfiles: profiles))
                .write(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let gate = SpeakerTestGate<SpeakerVoiceEmbedding>(), log = SpeakerExtractionTestLog()
            let result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                let id = url.deletingPathExtension().lastPathComponent
                await log.record(id)
                if id == "first-source" { return await gate.extract() }
                return result
            }, prepareMeeting: { _ in XCTFail("Completed meetings must skip preparation") })
            let task = Task { try await recognition.updateMeeting(recordID: "candidate") }
            await gate.waitUntilStarted()
            XCTAssertTrue(recognition.processingProfileIDs.contains("first"))
            try recognition.disableVoiceMatching(profileID: "second")
            await gate.release(result)
            try await task.value

            XCTAssertTrue(store.profile(withID: "first")?.hasCurrentVoiceSample == true)
            XCTAssertFalse(store.profile(withID: "second")?.voiceMatchingEnabled ?? true)
            XCTAssertNil(store.profile(withID: "second")?.voiceSamples)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "second-source"), "second")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "candidate"), "first")
            XCTAssertEqual(store.speakerProfiles.count, 2)
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["first-source", "candidate"])
            let reloaded = AudioAnalyticsStore(storageURL: storage)
            XCTAssertFalse(reloaded.profile(withID: "second")?.voiceMatchingEnabled ?? true)
            XCTAssertNil(reloaded.profile(withID: "second")?.voiceSamples)
        }
    }

    func testProfileLinksDifferentSpeakerNumbersAndRenameUpdatesEveryLinkedMeeting() throws {
        try withStore { store, directory in
            addRecording("first", to: store, in: directory)
            addRecording("second", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: profile.id)
            try store.linkSpeaker(speakerID: 1, recordID: "second", profileID: profile.id)
            // Linking the second voice merges its assignments into the existing participant.
            try store.linkSpeaker(speakerID: 1, recordID: "first", profileID: profile.id)
            try store.renameSpeakerProfile(id: profile.id, name: " Alex\nRivera ")

            XCTAssertEqual(store.profile(withID: profile.id)?.name, "Alex Rivera")
            XCTAssertEqual(Set(store.records(linkedToProfileID: profile.id).map(\.id)), ["first", "second"])
            XCTAssertEqual(store.record(withID: "first")?.diarization?.speakerName(0), "Alex Rivera")
            XCTAssertEqual(store.record(withID: "first")?.diarization?.speakerIDs, [0])
            XCTAssertNil(store.profileID(speakerID: 1, recordID: "first"))
            XCTAssertEqual(store.record(withID: "second")?.diarization?.speakerName(1), "Alex Rivera")
            XCTAssertEqual(store.record(withID: "second")?.diarization?.speakerName(0), "Speaker 1")
            XCTAssertEqual(store.record(withID: "first")?.transcript, "Hello. Good morning.")
            XCTAssertTrue(store.record(withID: "first")?.displayTranscript.contains("Alex Rivera: Hello.") == true)

            let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            XCTAssertEqual(reloaded.profileID(speakerID: 1, recordID: "second"), profile.id)
            XCTAssertEqual(reloaded.record(withID: "first")?.diarization?.speakerName(0), "Alex Rivera")
        }
    }

    func testCorrectingOneMeetingKeepsOtherLinksAndRemovesOnlyIncorrectEnrollment() throws {
        try withStore { store, directory in
            addRecording("first", to: store, in: directory)
            addRecording("second", to: store, in: directory)
            let alex = try store.createSpeakerProfile(name: "Alex")
            let priya = try store.createSpeakerProfile(name: "Priya")
            for id in ["first", "second"] {
                try store.linkSpeaker(speakerID: 0, recordID: id, profileID: alex.id)
                try enroll(alex.id, recordID: id, speakerID: 0, store: store)
            }

            try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: priya.id)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "first"), priya.id)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "second"), alex.id)
            XCTAssertEqual(store.records(linkedToProfileID: alex.id).map(\.id), ["second"])
            XCTAssertEqual(store.records(linkedToProfileID: priya.id).map(\.id), ["first"])
            XCTAssertEqual(store.profile(withID: alex.id)?.voiceSamples?.map(\.recordID), ["second"])
            XCTAssertTrue(store.profile(withID: priya.id)?.voiceSamples?.isEmpty ?? true)
            XCTAssertEqual(store.record(withID: "second")?.diarization?.speakerName(0), "Alex")
        }
    }

    func testSavingTheSamePersonKeepsTheirEnrolledVoice() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            try enroll(profile.id, recordID: "meeting", speakerID: 0, store: store)
            let enrolled = try XCTUnwrap(store.profile(withID: profile.id))

            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            XCTAssertEqual(store.profile(withID: profile.id), enrolled)
            XCTAssertEqual(store.records(linkedToProfileID: profile.id).count, 1)
        }
    }

    func testChangingEnrollmentInvalidatesPendingMatchesWhileKeepingUnrelatedSuggestions() throws {
        for mutation in ["correct", "unlink", "remove-record", "regenerate"] {
            for keepAnotherSample in [false, true] {
                try withStore { store, directory in
                    var store = store
                    for id in ["first", "second", "candidate"] { addRecording(id, to: store, in: directory) }
                    let alex = try store.createSpeakerProfile(name: "Alex")
                    let priya = try store.createSpeakerProfile(name: "Priya")
                    let other = try store.createSpeakerProfile(name: "Other person")
                    try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: alex.id)
                    try enroll(alex.id, recordID: "first", speakerID: 0, store: store)
                    if keepAnotherSample {
                        try store.linkSpeaker(speakerID: 0, recordID: "second", profileID: alex.id)
                        try enroll(alex.id, recordID: "second", speakerID: 0, store: store)
                    }
                    try store.linkSpeaker(speakerID: 1, recordID: "second", profileID: other.id)
                    try enroll(other.id, recordID: "second", speakerID: 1, store: store)
                    store = try loadingSuggestion(.init(profileID: alex.id, similarity: 0.999), speakerID: 0, recordID: "candidate",
                        store: store, in: directory)
                    let unaffected = AudioSpeakerSuggestion(profileID: other.id, similarity: 0.999)
                    store = try loadingSuggestion(unaffected, speakerID: 1, recordID: "candidate",
                        store: store, in: directory)

                    switch mutation {
                    case "correct":
                        try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: priya.id)
                    case "unlink":
                        try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: nil)
                    case "remove-record":
                        store.removeRecord(withID: "first")
                    default:
                        addRecording("first", to: store, in: directory, diarization: fixtureDiarization(offset: 0.5))
                    }

                    let context = "\(mutation), another sample: \(keepAnotherSample)"
                    let updated = try XCTUnwrap(store.profile(withID: alex.id))
                    XCTAssertEqual(updated.voiceMatchingEnabled, keepAnotherSample, context)
                    XCTAssertEqual(updated.voiceSamples?.map(\.recordID) ?? [], keepAnotherSample ? ["second"] : [], context)
                    XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"], context)
                    XCTAssertEqual(store.record(withID: "candidate")?.diarization?.speakerSuggestions?["1"], unaffected, context)
                    let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
                    XCTAssertNil(reloaded.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"], context)
                    XCTAssertEqual(reloaded.record(withID: "candidate")?.diarization?.speakerSuggestions?["1"], unaffected, context)
                }
            }
        }
    }

    func testUnlinkKeepsAudioAndTranscriptAndDoesNotRenameOtherMeetings() throws {
        try withStore { store, directory in
            addRecording("first", to: store, in: directory)
            addRecording("second", to: store, in: directory)
            let audio = directory.appendingPathComponent("first.wav")
            let audioBytes = Data("original audio remains untouched".utf8)
            try audioBytes.write(to: audio)
            let profile = try store.createSpeakerProfile(name: "Alex")
            for id in ["first", "second"] {
                try store.linkSpeaker(speakerID: 0, recordID: id, profileID: profile.id)
            }
            let before = try XCTUnwrap(store.record(withID: "first"))
            try store.linkSpeaker(speakerID: 0, recordID: "first", profileID: nil)

            let after = try XCTUnwrap(store.record(withID: "first"))
            assertRecordingContent(after, equals: before)
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "first"))
            XCTAssertEqual(after.diarization?.speakerName(0), "Speaker 1")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "second"), profile.id)
            XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
        }
    }

    func testDeletingProfileKeepsMeetingNamesAudioAndTranscript() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let audio = directory.appendingPathComponent("meeting.wav")
            let audioBytes = Data([0, 1, 2, 3, 4])
            try audioBytes.write(to: audio)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: profile.id)
            try enroll(profile.id, recordID: "meeting", speakerID: 1, store: store)
            let before = try XCTUnwrap(store.record(withID: "meeting"))

            try store.deleteSpeakerProfile(id: profile.id)
            let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            let after = try XCTUnwrap(reloaded.record(withID: "meeting"))
            XCTAssertTrue(reloaded.speakerProfiles.isEmpty)
            XCTAssertNil(reloaded.profileID(speakerID: 1, recordID: "meeting"))
            XCTAssertEqual(after.diarization?.speakerName(1), "Alex")
            assertRecordingContent(after, equals: before)
            XCTAssertEqual(after.displayTranscript, before.displayTranscript)
            XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
        }
    }

    func testRegenerationPreservesLinksOnlyForIdenticalDiarization() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            try enroll(profile.id, recordID: "meeting", speakerID: 0, store: store)
            let samples = store.profile(withID: profile.id)?.voiceSamples

            addRecording("meeting", to: store, in: directory, transcript: "A corrected transcript.")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), profile.id)
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerName(0), "Alex")
            XCTAssertEqual(store.profile(withID: profile.id)?.voiceSamples, samples)
            XCTAssertEqual(store.record(withID: "meeting")?.transcript, "A corrected transcript.")

            addRecording("meeting", to: store, in: directory, diarization: fixtureDiarization(offset: 0.5))
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "meeting"))
            XCTAssertTrue(store.records(linkedToProfileID: profile.id).isEmpty)
            XCTAssertTrue(store.profile(withID: profile.id)?.voiceSamples?.isEmpty ?? true)
            XCTAssertFalse(store.profile(withID: profile.id)?.voiceMatchingEnabled ?? true)
            XCTAssertEqual(store.record(withID: "meeting")?.audioFileName, "meeting.wav")
        }
    }

    func testVoiceOptOutRemovesVectorsAndSuggestionsButKeepsConfirmedLinks() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            XCTAssertThrowsError(try store.setVoiceMatchingEnabled(true, profileID: profile.id))
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            store = try loadingSuggestion(.init(profileID: profile.id, similarity: 0.95), speakerID: 0, recordID: "candidate",
                store: store, in: directory)

            try store.setVoiceMatchingEnabled(false, profileID: profile.id)
            let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            let updated = try XCTUnwrap(reloaded.profile(withID: profile.id))
            XCTAssertFalse(updated.voiceMatchingEnabled)
            XCTAssertNil(updated.voiceSamples)
            XCTAssertEqual(reloaded.profileID(speakerID: 0, recordID: "source"), profile.id)
            XCTAssertEqual(reloaded.record(withID: "source")?.diarization?.speakerName(0), "Alex")
            XCTAssertNil(reloaded.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"])
        }
    }

    func testFailedProfileWritesDoNotChangeInMemoryProfilesOrRecordingLinks() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            let profiles = store.speakerProfiles
            let records = store.records
            let storage = directory.appendingPathComponent("records.json")
            // A directory at the file destination produces a deterministic write failure.
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)

            XCTAssertThrowsError(try store.renameSpeakerProfile(id: profile.id, name: "Changed"))
            XCTAssertThrowsError(try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: nil))
            XCTAssertThrowsError(try store.deleteSpeakerProfile(id: profile.id))
            XCTAssertThrowsError(try store.createSpeakerProfile(name: "New person"))
            XCTAssertEqual(store.speakerProfiles, profiles)
            XCTAssertEqual(store.records, records)
        }
    }

    func testExistingMeetingLabelDoesNotAutomaticallyIdentifyAProfileWithTheSameName() throws {
        try withDirectory { directory in
            let storage = directory.appendingPathComponent("records.json")
            var record = fixtureRecord(id: "legacy")
            record.diarization?.speakerNames = ["0": "Alex"]
            try JSONEncoder().encode([record]).write(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let profile = try store.createSpeakerProfile(name: "Alex")

            XCTAssertEqual(store.record(withID: "legacy")?.diarization?.speakerName(0), "Alex")
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "legacy"))
            XCTAssertTrue(store.records(linkedToProfileID: profile.id).isEmpty)
            XCTAssertNil(store.record(withID: "legacy")?.diarization?.speakerSuggestions)
        }
    }

    func testAcceptedVoiceCandidateRequiresConfirmationBeforeLinkingMeeting() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("new-meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            let suggestion = try XCTUnwrap(AudioSpeakerMatcher.suggestion(
                for: embedding(), profiles: store.speakerProfiles, excludingRecordID: "new-meeting"
            ))
            store = try loadingSuggestion(suggestion, speakerID: 0, recordID: "new-meeting",
                store: store, in: directory)

            XCTAssertNil(store.profileID(speakerID: 0, recordID: "new-meeting"))
            XCTAssertEqual(store.records(linkedToProfileID: profile.id).count, 1)
            XCTAssertEqual(store.record(withID: "new-meeting")?.diarization?.speakerName(0), "Speaker 1")
            XCTAssertEqual(store.record(withID: "new-meeting")?.diarization?.speakerSuggestions?["0"], suggestion)

            try store.linkSpeaker(speakerID: 0, recordID: "new-meeting", profileID: suggestion.profileID)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "new-meeting"), profile.id)
            XCTAssertEqual(store.records(linkedToProfileID: profile.id).count, 2)
            XCTAssertNil(store.record(withID: "new-meeting")?.diarization?.speakerSuggestions?["0"])
        }
    }

    func testDismissedSuggestionIsNotShownAgainAndDoesNotCreateALink() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            store = try loadingSuggestion(.init(profileID: profile.id, similarity: 0.95), speakerID: 0, recordID: "candidate",
                store: store, in: directory)
            try store.dismissSpeakerSuggestion(speakerID: 0, recordID: "candidate")
            let diarization = try XCTUnwrap(store.record(withID: "candidate")?.diarization)

            XCTAssertNil(diarization.speakerSuggestions?["0"])
            XCTAssertNil(store.profileID(speakerID: 0, recordID: "candidate"))
            XCTAssertEqual(diarization.dismissedSpeakerSuggestions?["0"], [profile.id])
            XCTAssertNil(AudioSpeakerMatcher.suggestion(for: embedding(), profiles: store.speakerProfiles,
                excludingRecordID: "candidate", dismissedProfileIDs: Set(diarization.dismissedSpeakerSuggestions?["0"] ?? [])))
        }
    }

    func testEnrollmentRejectsAResultAfterTheSpeakerWasCorrected() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let alex = try store.createSpeakerProfile(name: "Alex")
            let priya = try store.createSpeakerProfile(name: "Priya")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: alex.id)
            let expected = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: priya.id)

            XCTAssertThrowsError(try store.enrollVoice(embedding(), profileID: alex.id,
                recordID: "meeting", speakerID: 0, expectedDiarization: expected))
            XCTAssertTrue(store.profile(withID: alex.id)?.voiceSamples?.isEmpty ?? true)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "meeting"), priya.id)
        }
    }

    func testEnrollmentCancellationOrOptOutWhileExtractingDoesNotPersistVoice() async throws {
        for optOut in [false, true] {
            try await withAsyncStore { store, directory in
                addRecording("source", to: store, in: directory)
                let profile = try store.createSpeakerProfile(name: "Alex")
                try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
                let gate = SpeakerTestGate<SpeakerVoiceEmbedding>()
                let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                    directory.appendingPathComponent("\(record.id).wav")
                }, extract: { _, _, _ in await gate.extract() })
                let task = Task { try await recognition.enableVoiceMatching(profileID: profile.id) }
                await gate.waitUntilStarted()
                XCTAssertTrue(recognition.processingProfileIDs.contains(profile.id))

                if optOut { try recognition.disableVoiceMatching(profileID: profile.id) }
                else { task.cancel() }
                await gate.release(embedding())
                do {
                    try await task.value
                    XCTFail("An interrupted enrollment must throw cancellation")
                } catch is CancellationError {}

                let updated = try XCTUnwrap(store.profile(withID: profile.id))
                XCTAssertFalse(updated.voiceMatchingEnabled)
                XCTAssertNil(updated.voiceSamples)
                XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), profile.id)
                XCTAssertFalse(recognition.processingProfileIDs.contains(profile.id))
                XCTAssertNil(recognition.errorMessage)
                let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
                XCTAssertFalse(reloaded.profile(withID: profile.id)?.voiceMatchingEnabled ?? true)
                XCTAssertNil(reloaded.profile(withID: profile.id)?.voiceSamples)
            }
        }
    }

    func testNewerUnusableMeetingsDoNotHideAnOlderValidEnrollmentSample() async throws {
        try await withAsyncStore { store, directory in
            let baseline = Date(timeIntervalSince1970: 1_700_000_000)
            addRecording("older-valid", to: store, in: directory, recordedAt: baseline)
            addRecording("newer-overlap", to: store, in: directory,
                diarization: AudioDiarization(modelID: "model", revision: "revision", segments: [
                    .init(start: 0, end: 5, speaker: 0), .init(start: 0, end: 5, speaker: 1),
                ]), recordedAt: baseline.addingTimeInterval(10))
            addRecording("newer-short", to: store, in: directory,
                diarization: AudioDiarization(modelID: "model", revision: "revision", segments: [
                    .init(start: 0, end: 1, speaker: 0),
                ]), recordedAt: baseline.addingTimeInterval(20))
            addRecording("newer-unavailable", to: store, in: directory, recordedAt: baseline.addingTimeInterval(30))
            let profile = try store.createSpeakerProfile(name: "Alex")
            for record in store.records {
                try store.linkSpeaker(speakerID: 0, recordID: record.id, profileID: profile.id)
            }
            XCTAssertEqual(store.records(linkedToProfileID: profile.id).map(\.id),
                ["newer-unavailable", "newer-short", "newer-overlap", "older-valid"])
            let log = SpeakerExtractionTestLog()
            let result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                record.id == "newer-unavailable" ? nil : directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.deletingPathExtension().lastPathComponent)
                return result
            })

            try await recognition.enableVoiceMatching(profileID: profile.id)

            let extractedRecords = await log.recordIDs
            XCTAssertEqual(extractedRecords, ["older-valid"])
            XCTAssertTrue(store.profile(withID: profile.id)?.voiceMatchingEnabled == true)
            XCTAssertEqual(store.profile(withID: profile.id)?.voiceSamples?.map(\.recordID), ["older-valid"])
            XCTAssertTrue(recognition.processingProfileIDs.isEmpty)
        }
    }

    func testChangedDiarizationRevisionRejectsOldLinkAndEnrollmentResults() throws {
        try withStore { store, directory in
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            let expected = try XCTUnwrap(store.record(withID: "candidate")?.diarization)
            let changed = AudioDiarization(modelID: expected.modelID, revision: "new-revision",
                segments: expected.segments, transcriptSegments: expected.transcriptSegments)
            addRecording("candidate", to: store, in: directory, diarization: changed)

            XCTAssertThrowsError(try store.linkSpeaker(speakerID: 0, recordID: "candidate",
                profileID: profile.id, expectedDiarization: expected))
            try store.linkSpeaker(speakerID: 0, recordID: "candidate", profileID: profile.id)
            XCTAssertThrowsError(try store.enrollVoice(embedding(), profileID: profile.id, recordID: "candidate",
                speakerID: 0, expectedDiarization: expected))
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"])
            XCTAssertEqual(store.profile(withID: profile.id)?.voiceSamples?.map(\.recordID), ["source"])
        }
    }

    func testMaintainedModelCopyReusesSavedUpstreamEmbeddingsWithoutRewritingStorage() throws {
        try withStore { store, directory in
            addRecording("source", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            let upstream = embedding(modelID: "aufklarer/SpeechBrain-ECAPA-VoxCeleb-20M-MLX",
                                     revision: "e749e6e08557f4a3ceb6ce3bf6f0b79efe592a77")
            try store.enrollVoice(upstream, profileID: profile.id, recordID: "source", speakerID: 0,
                                  expectedDiarization: XCTUnwrap(store.record(withID: "source")?.diarization))
            let storage = directory.appendingPathComponent("records.json")
            let before = try Data(contentsOf: storage)
            let reloaded = AudioAnalyticsStore(storageURL: storage)
            let saved = try XCTUnwrap(reloaded.profile(withID: profile.id))
            XCTAssertFalse(saved.needsVoiceReenrollment)
            XCTAssertEqual(saved.voiceSamples?.first?.embedding, upstream)
            XCTAssertEqual(AudioSpeakerMatcher.suggestion(for: embedding(), profiles: [saved], excludingRecordID: "new")?.profileID, profile.id)
            XCTAssertTrue(AudioSpeakerSuggestion(profileID: profile.id, similarity: 1,
                modelID: upstream.modelID, revision: upstream.revision).usesCurrentVoiceModel)
            XCTAssertEqual(try Data(contentsOf: storage), before)
            let wrongRevision = embedding(modelID: upstream.modelID, revision: "unverified")
            XCTAssertThrowsError(try wrongRevision.validate())
        }
    }

    func testMatcherLeavesUnknownAndAmbiguousVoicesUnassigned() throws {
        let query = embedding()
        XCTAssertNil(AudioSpeakerMatcher.suggestion(for: query,
            profiles: [voiceProfile("unknown", embedding: embedding(similarity: 0.74))], excludingRecordID: "new"))
        XCTAssertNil(AudioSpeakerMatcher.suggestion(for: query,
            profiles: [voiceProfile("first", embedding: embedding(similarity: 0.90)),
                       voiceProfile("second", embedding: embedding(similarity: 0.80))], excludingRecordID: "new"))
        let distinct = AudioSpeakerMatcher.suggestion(for: query,
            profiles: [voiceProfile("first", embedding: embedding(similarity: 0.90)),
                       voiceProfile("second", embedding: embedding(similarity: 0.20))], excludingRecordID: "new")
        XCTAssertEqual(distinct?.profileID, "first")
        XCTAssertEqual(try XCTUnwrap(distinct?.similarity), 0.90, accuracy: 0.00001)
    }

    func testMatcherExcludesSameRecordingDisabledProfilesAndOtherModelRevisions() {
        let query = embedding()
        var disabled = voiceProfile("disabled", embedding: query)
        disabled.voiceMatchingEnabled = false
        let oldRevision = SpeakerVoiceEmbedding(modelID: query.modelID, revision: "old-revision",
            vector: query.vector, durationSeconds: query.durationSeconds)
        let otherModel = SpeakerVoiceEmbedding(modelID: "other-model", revision: query.revision,
            vector: query.vector, durationSeconds: query.durationSeconds)
        for profile in [disabled, voiceProfile("same-recording", embedding: query, recordID: "new"),
                        voiceProfile("old", embedding: oldRevision), voiceProfile("other", embedding: otherModel)] {
            XCTAssertNil(AudioSpeakerMatcher.suggestion(for: query, profiles: [profile], excludingRecordID: "new"), profile.id)
        }
    }

    func testMatcherRequiresAgreementAcrossConfirmedSamplesAndRejectsInvalidQuery() {
        let query = embedding()
        var profile = voiceProfile("mixed", embedding: query)
        profile.voiceSamples?.append(.init(recordID: "different", speakerID: 1, embedding: embedding(similarity: 0.3)))
        XCTAssertNil(AudioSpeakerMatcher.suggestion(for: query, profiles: [profile], excludingRecordID: "new"))
        let invalid = SpeakerVoiceEmbedding(modelID: query.modelID, revision: query.revision,
            vector: [1, 0], durationSeconds: 5)
        XCTAssertNil(AudioSpeakerMatcher.suggestion(for: invalid,
            profiles: [voiceProfile("valid", embedding: query)], excludingRecordID: "new"))
    }

    func testEncoderMigrationClearsLegacyVectorsAndCandidatesButKeepsConfirmedIdentities() throws {
        try withDirectory { directory in
            let storage = directory.appendingPathComponent("records.json")
            let original = try writeLegacyVoiceStorage(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)

            let profile = try XCTUnwrap(store.profile(withID: "alex"))
            XCTAssertTrue(profile.voiceMatchingEnabled)
            XCTAssertTrue(profile.needsVoiceReenrollment)
            XCTAssertNil(profile.voiceSamples)
            XCTAssertEqual(profile.name, "Alex")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
            XCTAssertEqual(store.record(withID: "source")?.diarization?.speakerName(0), "Alex")
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions)
            XCTAssertEqual(store.record(withID: "candidate")?.diarization?.dismissedSpeakerSuggestions?["1"], ["alex"])
            for record in original {
                assertRecordingContent(try XCTUnwrap(store.record(withID: record.id)), equals: record)
            }
            XCTAssertNil(AudioSpeakerMatcher.suggestion(for: embedding(),
                profiles: [voiceProfile("legacy", embedding: legacyEmbedding())], excludingRecordID: "new"))
            XCTAssertThrowsError(try store.setVoiceMatchingEnabled(true, profileID: "alex"))

            let reloaded = AudioAnalyticsStore(storageURL: storage)
            XCTAssertTrue(reloaded.profile(withID: "alex")?.needsVoiceReenrollment == true)
            XCTAssertNil(reloaded.profile(withID: "alex")?.voiceSamples)
            XCTAssertEqual(reloaded.profileID(speakerID: 0, recordID: "source"), "alex")
            XCTAssertNil(reloaded.record(withID: "candidate")?.diarization?.speakerSuggestions)
        }
    }

    func testMigratedOptInReenrollsFromConfirmedSourceBeforeAutomaticLinking() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            try writeLegacyVoiceStorage(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let log = SpeakerExtractionTestLog()
            let result = embedding()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { url, _, _ in
                await log.record(url.deletingPathExtension().lastPathComponent)
                return result
            })

            try await recognition.updateMeeting(recordID: "candidate")

            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["source", "candidate", "candidate"])
            let refreshed = try XCTUnwrap(store.profile(withID: "alex"))
            XCTAssertTrue(refreshed.voiceMatchingEnabled)
            XCTAssertFalse(refreshed.needsVoiceReenrollment)
            XCTAssertEqual(refreshed.voiceSamples?.map(\.embedding), [result])
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "candidate"), "alex")
            XCTAssertEqual(store.record(withID: "candidate")?.diarization?.speakerName(0), "Alex")
            XCTAssertNil(store.profileID(speakerID: 1, recordID: "candidate"), "A dismissed link must stay unassigned")
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions?["0"])
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions?["1"])
            let reloaded = AudioAnalyticsStore(storageURL: storage)
            XCTAssertEqual(reloaded.profileID(speakerID: 0, recordID: "candidate"), "alex")
            XCTAssertEqual(reloaded.profile(withID: "alex")?.voiceSamples?.map(\.embedding), [result])
        }
    }

    func testEncoderMigrationKeepsCurrentSamplesWhenMixedWithLegacyVectors() throws {
        try withDirectory { directory in
            let storage = directory.appendingPathComponent("records.json")
            let current = embedding()
            try writeLegacyVoiceStorage(to: storage, additionalEmbedding: current)
            let store = AudioAnalyticsStore(storageURL: storage)
            let profile = try XCTUnwrap(store.profile(withID: "alex"))
            XCTAssertTrue(profile.voiceMatchingEnabled)
            XCTAssertFalse(profile.needsVoiceReenrollment)
            XCTAssertEqual(profile.voiceSamples?.map(\.embedding), [current])
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
        }
    }

    func testMigratedProfileOptOutDuringReenrollmentDoesNotSaveOrSuggest() async throws {
        try await withAsyncStore { _, directory in
            let storage = directory.appendingPathComponent("records.json")
            try writeLegacyVoiceStorage(to: storage)
            let store = AudioAnalyticsStore(storageURL: storage)
            let gate = SpeakerTestGate<SpeakerVoiceEmbedding>()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                directory.appendingPathComponent("\(record.id).wav")
            }, extract: { _, _, _ in await gate.extract() })
            let task = Task { try await recognition.updateMeeting(recordID: "candidate") }
            await gate.waitUntilStarted()
            try recognition.disableVoiceMatching(profileID: "alex")
            await gate.release(embedding())
            do {
                try await task.value
                XCTFail("Opting out must cancel re-enrollment")
            } catch is CancellationError {}

            XCTAssertFalse(store.profile(withID: "alex")?.voiceMatchingEnabled ?? true)
            XCTAssertNil(store.profile(withID: "alex")?.voiceSamples)
            XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions)
            XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
            XCTAssertTrue(recognition.processingRecordIDs.isEmpty)
            XCTAssertTrue(recognition.processingProfileIDs.isEmpty)
        }
    }

    func testMigrationReenrollsOnlyOptedInProfilesBeforeAutomaticMatching() async throws {
        for optedOut in [false, true] {
            try await withAsyncStore { _, directory in
                let storage = directory.appendingPathComponent("records.json")
                try writeLegacyVoiceStorage(to: storage, voiceMatchingEnabled: !optedOut)
                let store = AudioAnalyticsStore(storageURL: storage)
                let log = SpeakerExtractionTestLog()
                let result = embedding()
                let recognition = AudioSpeakerRecognition(store: store, audioURL: { record in
                    directory.appendingPathComponent("\(record.id).wav")
                }, extract: { url, _, _ in
                    await log.record(url.deletingPathExtension().lastPathComponent)
                    return result
                })
                try await recognition.updateMeeting(recordID: "candidate")
                let calls = await log.recordIDs
                XCTAssertEqual(calls, optedOut ? ["candidate", "candidate"] : ["source", "candidate", "candidate"])
                XCTAssertEqual(store.profile(withID: "alex")?.voiceSamples?.isEmpty ?? true, optedOut)
                XCTAssertEqual(store.profile(withID: "alex")?.voiceMatchingEnabled, !optedOut)
                XCTAssertEqual(store.profileID(speakerID: 0, recordID: "source"), "alex")
                XCTAssertNil(store.record(withID: "source")?.diarization?.speakerSuggestions)
            }
        }
    }

    func testOldEncoderCandidateIsDiscardedWhenLoadingCurrentVoiceEnrollment() throws {
        try withStore { store, directory in
            var store = store
            addRecording("source", to: store, in: directory)
            addRecording("candidate", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Alex")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            for candidate in [
                AudioSpeakerSuggestion(profileID: profile.id, similarity: 0.999, modelID: nil, revision: nil),
                AudioSpeakerSuggestion(profileID: profile.id, similarity: 0.999,
                    modelID: legacyEmbedding().modelID, revision: legacyEmbedding().revision),
            ] {
                store = try loadingSuggestion(candidate, speakerID: 0, recordID: "candidate",
                    store: store, in: directory)
                XCTAssertNil(store.record(withID: "candidate")?.diarization?.speakerSuggestions)
            }
        }
    }

    func testVoiceWindowsExcludeOverlappingSpeechAndTrimTurnBoundaries() throws {
        let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: [
            .init(start: 0, end: 20, speaker: 0),
            .init(start: 4, end: 8, speaker: 1),
            .init(start: 12, end: 16, speaker: 1),
        ])
        let windows = try SpeakerVoiceEmbeddingExtractor.windows(diarization: diarization, speakerID: 0)
        XCTAssertEqual(windows, [
            .init(start: 0.15, end: 3.85),
            .init(start: 8.15, end: 11.85),
            .init(start: 16.15, end: 19.85),
        ])
        for window in windows {
            for otherSpeaker in diarization.segments where otherSpeaker.speaker != 0 {
                XCTAssertTrue(window.end <= otherSpeaker.start || window.start >= otherSpeaker.end)
            }
        }
    }

    func testVoiceWindowsKeepExactlyThreeSecondsAfterTrimmingOnThePCMGrid() throws {
        for (start, end) in [(0.0, 3.3), (10.3, 13.6), (20.6, 23.9)] {
            let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: [
                .init(start: start, end: end, speaker: 0),
            ])
            let windows = try SpeakerVoiceEmbeddingExtractor.windows(diarization: diarization, speakerID: 0)
            XCTAssertEqual(windows.count, 1)
            let window = try XCTUnwrap(windows.first)
            XCTAssertEqual(window.start, start + 0.15, accuracy: 1 / 16000)
            XCTAssertEqual(window.end - window.start, 3, accuracy: 1 / 16000)
        }
    }

    func testVoiceWindowsBoundLongRecordingsToThirtySecondsOfContiguousSamples() throws {
        let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: [
            .init(start: 7_200, end: 7_300, speaker: 0),
        ])
        let windows = try SpeakerVoiceEmbeddingExtractor.windows(diarization: diarization, speakerID: 0)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.end - $1.start }, 30, accuracy: 1 / 16000)
        for window in windows {
            XCTAssertGreaterThanOrEqual(window.end - window.start, 3 - 1 / 16000)
            XCTAssertLessThanOrEqual(window.end - window.start, 10 + 1 / 16000)
            XCTAssertGreaterThanOrEqual(window.start, 7_200.15)
            XCTAssertLessThanOrEqual(window.end, 7_299.85)
        }
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            XCTAssertLessThan(earlier.end, later.start)
        }
    }

    func testVoiceWindowsRejectShortFragmentedOverlappedOrMissingSpeakers() {
        let fixtures: [(segments: [AudioDiarization.Segment], speaker: Int)] = [
            ([.init(start: 0, end: 3.29, speaker: 0)], 0),
            ([.init(start: 0, end: 10, speaker: 0), .init(start: 0, end: 10, speaker: 1)], 0),
            ([.init(start: 0, end: 1.5, speaker: 0), .init(start: 3, end: 4.5, speaker: 0),
              .init(start: 6, end: 7.5, speaker: 0)], 0),
            ([.init(start: 0, end: 10, speaker: 0)], 2),
        ]
        for fixture in fixtures {
            let diarization = AudioDiarization(modelID: "model", revision: "revision", segments: fixture.segments)
            XCTAssertThrowsError(try SpeakerVoiceEmbeddingExtractor.windows(diarization: diarization, speakerID: fixture.speaker)) { error in
                guard case SpeakerVoiceEmbeddingError.insufficientSpeech = error else {
                    return XCTFail("Expected insufficient speech, got \(error)")
                }
            }
        }
    }

    func testVoiceEmbeddingValidationRejectsWrongModelRevisionShapeAndUnusableSamples() throws {
        let valid = embedding()
        try valid.validate()
        for duration in [3.0, 30.0] { try embedding(durationSeconds: duration).validate() }
        var nonFinite = valid.vector
        nonFinite[100] = .nan
        var nonUnit = valid.vector
        nonUnit[0] = 2
        let invalid = [
            embedding(modelID: "other-model"),
            embedding(revision: "other-revision"),
            embedding(vectorOverride: Array(valid.vector.dropLast())),
            embedding(vectorOverride: nonFinite),
            embedding(vectorOverride: nonUnit),
            embedding(vectorOverride: [Float](repeating: 0, count: SpeakerVoiceEmbeddingExtractor.dimensions)),
            legacyEmbedding(),
        ] + [2.999, 30.001, Double.nan, Double.infinity].map { embedding(durationSeconds: $0) }
        for sample in invalid {
            XCTAssertThrowsError(try sample.validate()) { error in
                guard case SpeakerVoiceEmbeddingError.invalidEmbedding = error else {
                    return XCTFail("Expected invalid embedding, got \(error)")
                }
            }
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func assertNoStorageWrite(_ storage: URL, file: StaticString = #filePath, line: UInt = #line,
                                      _ body: () throws -> Void) throws {
        let original = try Data(contentsOf: storage)
        let marker = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: storage.path)
        try body()
        XCTAssertEqual(try Data(contentsOf: storage), original, file: file, line: line)
        let modified = try FileManager.default.attributesOfItem(atPath: storage.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, marker, file: file, line: line)
    }

    private func assertNoStorageWriteAsync(_ storage: URL, file: StaticString = #filePath, line: UInt = #line,
                                           _ body: () async throws -> Void) async throws {
        let original = try Data(contentsOf: storage)
        let marker = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: storage.path)
        try await body()
        XCTAssertEqual(try Data(contentsOf: storage), original, file: file, line: line)
        let modified = try FileManager.default.attributesOfItem(atPath: storage.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, marker, file: file, line: line)
    }

    private func withStore(_ body: (AudioAnalyticsStore, URL) throws -> Void) throws {
        try withDirectory { directory in
            try body(AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json")), directory)
        }
    }

    private func withAsyncStore(_ body: (AudioAnalyticsStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json")), directory)
    }

    func testLinkToExistingParticipantMergesPassagesAndUndoRestoresSeparateVoices() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            addRecording("other", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Me")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            let before = try XCTUnwrap(store.record(withID: "meeting"))
            let other = store.record(withID: "other")

            let undo = try store.linkSpeakerForReview(speakerID: 1, recordID: "meeting", profileID: profile.id)
            let merged = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            XCTAssertEqual(merged.groupedByProfile.speakerIDs, [0])
            XCTAssertEqual(merged.groupedByProfile.resolvedTranscriptSegments.map(\.speakers), [[0], [0]])
            XCTAssertEqual(merged.speakerIDs, [0])
            XCTAssertEqual(merged.segments.map(\.speaker), [0, 0])
            XCTAssertEqual(merged.transcriptSegments?.map(\.speakers), [[0], [0]])
            XCTAssertEqual(merged.transcriptSegments?.map(\.text), before.diarization?.transcriptSegments?.map(\.text))
            XCTAssertEqual(merged.transcriptSegments?.map(\.start), before.diarization?.transcriptSegments?.map(\.start))
            XCTAssertEqual(merged.transcriptSegments?.map(\.end), before.diarization?.transcriptSegments?.map(\.end))
            XCTAssertEqual(store.record(withID: "meeting")?.transcript, before.transcript)
            XCTAssertEqual(store.record(withID: "meeting")?.summary, before.summary)
            XCTAssertEqual(store.record(withID: "other"), other)
            XCTAssertEqual(AudioSpeakerReviewExcerpt.samples(in: merged.groupedByProfile, speakerID: 0).map(\.start), [0, 6])
            let reloaded = AudioAnalyticsStore(storageURL: directory.appendingPathComponent("records.json"))
            XCTAssertEqual(reloaded.record(withID: "meeting")?.diarization?.speakerIDs, [0])

            try store.undoSpeakerReview(undo)
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.groupedByProfile.speakerIDs, [0, 1])
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.transcriptSegments, before.diarization?.transcriptSegments)
        }
    }

    func testMergeKeepsExistingParticipantIDAndRejectsStaleUndo() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Me")
            try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: profile.id)
            let undo = try store.linkSpeakerForReview(speakerID: 0, recordID: "meeting", profileID: profile.id)
            let merged = try XCTUnwrap(store.record(withID: "meeting")?.diarization)
            XCTAssertEqual(merged.speakerIDs, [1])
            XCTAssertEqual(merged.transcriptSegments?.map(\.speakers), [[1], [1]])
            XCTAssertNil(merged.speakerNames?["0"])
            XCTAssertNil(merged.speakerProfileIDs?["0"])
            XCTAssertTrue(merged.speakerTranscript?.contains("Speaker 2: Hello.") == true)
            try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: nil)
            let current = store.records
            XCTAssertThrowsError(try store.undoSpeakerReview(undo))
            XCTAssertEqual(store.records, current)
        }
    }

    func testRelinkingLegacyDuplicatesRemapsAndDeduplicatesVoiceSamplesAndUndoRestoresThem() throws {
        for sampledSpeakers in [[0], [1], [0, 1]] {
            try withDirectory { directory in
                var record = fixtureRecord(id: "meeting")
                record.diarization?.speakerProfileIDs = ["0": "me", "1": "me"]
                record.diarization?.speakerNames = ["0": "Me", "1": "Me"]
                var profile = voiceProfile("me", embedding: embedding(), recordID: "meeting")
                profile.name = "Me"
                profile.voiceSamples = sampledSpeakers.map {
                    .init(recordID: "meeting", speakerID: $0, embedding: embedding())
                }
                let storage = directory.appendingPathComponent("records.json")
                try JSONEncoder().encode(StorageFixture(records: [record], speakerProfiles: [profile])).write(to: storage)
                let store = AudioAnalyticsStore(storageURL: storage)
                let undo = try store.linkSpeakerForReview(speakerID: 0, recordID: "meeting", profileID: "me")
                XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerIDs, [1])
                XCTAssertEqual(store.profile(withID: "me")?.voiceSamples?.map(\.speakerID), [1])
                XCTAssertNotNil(store.voiceEmbedding(recordID: "meeting", speakerID: 1))
                XCTAssertNil(store.voiceEmbedding(recordID: "meeting", speakerID: 0))
                try store.undoSpeakerReview(undo)
                XCTAssertEqual(store.record(withID: "meeting")?.diarization, record.diarization)
                XCTAssertEqual(store.profile(withID: "me")?.voiceSamples, profile.voiceSamples)
            }
        }
    }

    func testFailedMergeSaveDoesNotChangeAssignmentsOrEmbeddings() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Me")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            try enroll(profile.id, recordID: "meeting", speakerID: 0, store: store)
            let records = store.records, profiles = store.speakerProfiles
            let storage = directory.appendingPathComponent("records.json")
            try FileManager.default.removeItem(at: storage)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.linkSpeaker(speakerID: 1, recordID: "meeting", profileID: profile.id))
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(store.speakerProfiles, profiles)
        }
    }

    func testMergeUndoRejectsNewVoiceEnrollmentWithoutRestoringStaleAssignments() throws {
        try withStore { store, directory in
            addRecording("meeting", to: store, in: directory)
            addRecording("other", to: store, in: directory)
            let profile = try store.createSpeakerProfile(name: "Me")
            try store.linkSpeaker(speakerID: 0, recordID: "meeting", profileID: profile.id)
            let undo = try store.linkSpeakerForReview(speakerID: 1, recordID: "meeting", profileID: profile.id)
            try store.linkSpeaker(speakerID: 0, recordID: "other", profileID: profile.id)
            try enroll(profile.id, recordID: "other", speakerID: 0, store: store)
            let records = store.records, profiles = store.speakerProfiles
            XCTAssertThrowsError(try store.undoSpeakerReview(undo))
            XCTAssertEqual(store.records, records)
            XCTAssertEqual(store.speakerProfiles, profiles)
        }
    }

    func testAutomaticMatchingContinuesAfterMergingSpeakerIDs() async throws {
        try await withAsyncStore { store, directory in
            addRecording("source", to: store, in: directory, diarization: soloDiarization())
            let profile = try store.createSpeakerProfile(name: "Me")
            try store.linkSpeaker(speakerID: 0, recordID: "source", profileID: profile.id)
            try enroll(profile.id, recordID: "source", speakerID: 0, store: store)
            let diarization = AudioDiarization(modelID: "model", revision: "test", segments: (0..<3).map {
                .init(start: Double($0 * 6), end: Double($0 * 6 + 5), speaker: $0)
            }, transcriptSegments: (0..<3).map {
                .init(start: Double($0 * 6), end: Double($0 * 6 + 5), speakers: [$0], text: "Passage \($0)")
            })
            addRecording("meeting", to: store, in: directory, diarization: diarization)
            let voice = embedding(), log = SpeakerExtractionTestLog()
            let recognition = AudioSpeakerRecognition(store: store, audioURL: {
                directory.appendingPathComponent("\($0.id).wav")
            }, extract: { _, _, speaker in
                await log.record(String(speaker))
                return voice
            })
            try await recognition.updateMeeting(recordID: "meeting")
            let calls = await log.recordIDs
            XCTAssertEqual(calls, ["0", "1", "2"])
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.speakerIDs, [0])
            XCTAssertEqual(store.record(withID: "meeting")?.diarization?.transcriptSegments?.map(\.speakers), [[0], [0], [0]])
            XCTAssertEqual(store.speakerProfiles.count, 1)
        }
    }

    /// Suggestions come from saved older recordings, not the automatic matching path.
    private func loadingSuggestion(_ suggestion: AudioSpeakerSuggestion, speakerID: Int, recordID: String,
                                   store: AudioAnalyticsStore, in directory: URL) throws -> AudioAnalyticsStore {
        var records = store.records
        let index = try XCTUnwrap(records.firstIndex { $0.id == recordID })
        var diarization = try XCTUnwrap(records[index].diarization)
        var suggestions = diarization.speakerSuggestions ?? [:]
        suggestions[String(speakerID)] = suggestion
        diarization.speakerSuggestions = suggestions
        records[index].diarization = diarization
        let storage = directory.appendingPathComponent("records.json")
        try JSONEncoder().encode(StorageFixture(records: records, speakerProfiles: store.speakerProfiles)).write(to: storage)
        return AudioAnalyticsStore(storageURL: storage)
    }

    private func fixtureDiarization(offset: Double = 0) -> AudioDiarization {
        AudioDiarization(modelID: "diarization-model", revision: "revision", segments: [
            .init(start: offset, end: 5 + offset, speaker: 0),
            .init(start: 6 + offset, end: 11 + offset, speaker: 1),
        ], transcriptSegments: [
            .init(start: offset, end: 5 + offset, speakers: [0], text: "Hello."),
            .init(start: 6 + offset, end: 11 + offset, speakers: [1], text: "Good morning."),
        ])
    }

    private func soloDiarization() -> AudioDiarization {
        AudioDiarization(modelID: "diarization-model", revision: "revision", segments: [
            .init(start: 0, end: 5, speaker: 0),
        ], transcriptSegments: [.init(start: 0, end: 5, speakers: [0], text: "Hello.")])
    }

    private func fixtureRecord(id: String) -> AudioTranscriptionRecord {
        AudioTranscriptionRecord(id: id, recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010), durationSeconds: 12,
            transcript: "Hello. Good morning.", modelID: "speech-model", applicationName: "Google Meet",
            kind: .meeting, title: "Team discussion", audioFileName: "\(id).wav", summary: "A saved summary.",
            diarization: fixtureDiarization())
    }

    private func addRecording(_ id: String, to store: AudioAnalyticsStore, in directory: URL,
                              transcript: String = "Hello. Good morning.", diarization: AudioDiarization? = nil,
                              recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        store.upsertTranscription(recordingURL: directory.appendingPathComponent("\(id).wav"),
            transcript: transcript, durationSeconds: 12, modelID: "speech-model", applicationName: "Google Meet",
            kind: .meeting, title: "Team discussion", persistAudioReference: true, summary: "A saved summary.",
            diarization: diarization ?? fixtureDiarization(), recordedAt: recordedAt)
    }

    private func enroll(_ profileID: String, recordID: String, speakerID: Int, store: AudioAnalyticsStore) throws {
        try store.enrollVoice(embedding(), profileID: profileID, recordID: recordID, speakerID: speakerID,
            expectedDiarization: XCTUnwrap(store.record(withID: recordID)?.diarization))
    }

    private func embedding(similarity: Double = 1,
                           modelID: String = SpeakerVoiceEmbeddingExtractor.modelID,
                           revision: String? = nil,
                           durationSeconds: Double = 5, vectorOverride: [Float]? = nil) -> SpeakerVoiceEmbedding {
        var vector = [Float](repeating: 0, count: SpeakerVoiceEmbeddingExtractor.dimensions)
        vector[0] = Float(similarity)
        vector[1] = Float(sqrt(max(0, 1 - similarity * similarity)))
        return SpeakerVoiceEmbedding(modelID: modelID, revision: revision,
            vector: vectorOverride ?? vector, durationSeconds: durationSeconds)
    }

    private func voiceProfile(_ id: String, embedding: SpeakerVoiceEmbedding, recordID: String = "source") -> AudioSpeakerProfile {
        AudioSpeakerProfile(id: id, name: id, createdAt: .distantPast, updatedAt: .distantPast,
            voiceMatchingEnabled: true, voiceSamples: [.init(recordID: recordID, speakerID: 0, embedding: embedding)])
    }

    private func legacyEmbedding() -> SpeakerVoiceEmbedding {
        var vector = [Float](repeating: 0, count: 2048)
        vector[0] = 1
        return SpeakerVoiceEmbedding(modelID: "marksverdhei/Qwen3-Voice-Embedding-12Hz-1.7B",
            revision: "7577f61c42737fc8064bba773e2a18602df92803", vector: vector, durationSeconds: 5)
    }

    @discardableResult
    private func writeLegacyVoiceStorage(to url: URL, voiceMatchingEnabled: Bool = true,
                                         additionalEmbedding: SpeakerVoiceEmbedding? = nil) throws -> [AudioTranscriptionRecord] {
        var source = fixtureRecord(id: "source"), candidate = fixtureRecord(id: "candidate")
        source.diarization?.speakerProfileIDs = ["0": "alex"]
        source.diarization?.speakerNames = ["0": "Alex"]
        candidate.diarization?.speakerSuggestions = ["0": .init(profileID: "alex", similarity: 0.999,
            modelID: nil, revision: nil)]
        candidate.diarization?.dismissedSpeakerSuggestions = ["1": ["alex"]]
        var profile = voiceProfile("alex", embedding: legacyEmbedding())
        profile.name = "Alex"
        profile.voiceMatchingEnabled = voiceMatchingEnabled
        if let additionalEmbedding {
            profile.voiceSamples?.append(.init(recordID: "source", speakerID: 0, embedding: additionalEmbedding))
        }
        let records = [source, candidate]
        try JSONEncoder().encode(StorageFixture(records: records, speakerProfiles: [profile])).write(to: url)
        return records
    }

    private func assertRecordingContent(_ record: AudioTranscriptionRecord, equals expected: AudioTranscriptionRecord,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(record.id, expected.id, file: file, line: line)
        XCTAssertEqual(record.recordedAt, expected.recordedAt, file: file, line: line)
        XCTAssertEqual(record.title, expected.title, file: file, line: line)
        XCTAssertEqual(record.audioFileName, expected.audioFileName, file: file, line: line)
        XCTAssertEqual(record.transcript, expected.transcript, file: file, line: line)
        XCTAssertEqual(record.summary, expected.summary, file: file, line: line)
        XCTAssertEqual(record.durationSeconds, expected.durationSeconds, file: file, line: line)
        XCTAssertEqual(record.diarization?.segments, expected.diarization?.segments, file: file, line: line)
        XCTAssertEqual(record.diarization?.transcriptSegments, expected.diarization?.transcriptSegments, file: file, line: line)
    }
}

private enum SpeakerTestError: Error { case extractionFailed }

private actor SpeakerTestGate<Value: Sendable> {
    private var hasStarted = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: CheckedContinuation<Value, Never>?

    func extract() async -> Value {
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters = []
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release(_ embedding: Value) {
        result?.resume(returning: embedding)
        result = nil
    }
}

private actor SpeakerExtractionTestLog {
    private(set) var recordIDs: [String] = []
    func record(_ recordID: String) { recordIDs.append(recordID) }
}

private struct StorageFixture: Encodable {
    let version = 1
    let records: [AudioTranscriptionRecord]
    let speakerProfiles: [AudioSpeakerProfile]
}
