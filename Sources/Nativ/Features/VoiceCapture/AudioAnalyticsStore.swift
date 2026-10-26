import Combine
import Foundation

enum AudioRecordKind: String, Codable, CaseIterable, Sendable {
    case dictation
    case voiceNote
    case meeting

    var title: String {
        switch self {
        case .dictation:
            "Dictation"
        case .voiceNote, .meeting:
            "Recording"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation:
            "text.cursor"
        case .voiceNote, .meeting:
            "waveform.badge.mic"
        }
    }
}

struct AudioTranscriptionRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let recordedAt: Date
    let updatedAt: Date
    let durationSeconds: TimeInterval?
    let transcript: String
    let modelID: String?
    let applicationName: String?
    let kind: AudioRecordKind?
    let title: String?
    let audioFileName: String?
    let summary: String?
    var diarization: AudioDiarization? = nil

    var displayTranscript: String {
        diarization?.formattedTranscript ?? transcript
    }

    var resolvedKind: AudioRecordKind {
        kind ?? .dictation
    }

    var displayTitle: String {
        if let title, !title.isEmpty {
            if resolvedKind != .dictation {
                for prefix in ["Meeting · ", "Voice note · ", "Voice Note · "]
                where title.hasPrefix(prefix) {
                    return "Recording · " + String(title.dropFirst(prefix.count))
                }
            }
            return title
        }
        return resolvedKind.title
    }

    var wordCount: Int {
        AudioAnalyticsStore.wordCount(in: transcript)
    }

    var wordsPerMinute: Double? {
        guard let durationSeconds, durationSeconds > 0 else {
            return nil
        }
        return Double(wordCount) / (durationSeconds / 60)
    }
}

struct AudioDailyUsage: Identifiable, Equatable, Sendable {
    let date: Date
    let words: Int
    let sessions: Int

    var id: Date { date }
}

struct AudioModelUsage: Identifiable, Equatable, Sendable {
    let modelID: String?
    let transcriptions: Int
    let dictations: Int
    let recordings: Int
    let words: Int
    let durationSeconds: TimeInterval
    let timedTranscriptions: Int
    let lastUsedAt: Date

    var id: String { modelID ?? "__unknown_transcription_model__" }
}

@MainActor
final class AudioAnalyticsStore: ObservableObject {
    static let shared = AudioAnalyticsStore()
    static let assumedTypingWordsPerMinute = 45.0

    @Published private(set) var records: [AudioTranscriptionRecord] = [] {
        didSet { cachedSpeakerReviewItems = nil }
    }
    @Published private(set) var speakerProfiles: [AudioSpeakerProfile] = [] {
        didSet { cachedSpeakerReviewItems = nil }
    }
    private var cachedSpeakerReviewItems: [AudioSpeakerReviewItem]?

    private let storageURL: URL
    private let calendar: Calendar
    private var storageReadFailed = false

    private struct Storage: Codable {
        let version: Int
        let records: [AudioTranscriptionRecord]
        let speakerProfiles: [AudioSpeakerProfile]
    }
    private var cachedWordCounts: [String: Int] = [:]
    private var cachedTotalWords = 0
    private var cachedAverageWordsPerMinute: Double?
    private var cachedEstimatedTimeSaved: TimeInterval = 0

    init(
        storageURL: URL? = nil,
        calendar: Calendar = .current
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.calendar = calendar
        load()
    }

    /// Refresh derived speaker lists without scheduling audio/model work.
    func refreshSpeakerDirectory() {
        cachedSpeakerReviewItems = nil
        objectWillChange.send()
    }

    var totalWords: Int {
        cachedTotalWords
    }

    var averageWordsPerMinute: Double? {
        cachedAverageWordsPerMinute
    }

    var estimatedTimeSaved: TimeInterval {
        cachedEstimatedTimeSaved
    }

    var currentStreak: Int {
        calculateCurrentStreak()
    }

    private func wordCount(for record: AudioTranscriptionRecord) -> Int {
        cachedWordCounts[record.id] ?? record.wordCount
    }

    private func rebuildDerivedMetrics() {
        cachedWordCounts = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0.wordCount) }
        )
        cachedTotalWords = records.reduce(0) { $0 + wordCount(for: $1) }

        let timed = records.compactMap { record -> (Int, TimeInterval)? in
            guard let duration = record.durationSeconds, duration > 0 else {
                return nil
            }
            return (wordCount(for: record), duration)
        }
        let duration = timed.reduce(0) { $0 + $1.1 }
        if duration > 0 {
            cachedAverageWordsPerMinute = Double(timed.reduce(0) { $0 + $1.0 }) / (duration / 60)
        } else {
            cachedAverageWordsPerMinute = nil
        }

        cachedEstimatedTimeSaved = records.reduce(0) { result, record in
            guard let duration = record.durationSeconds else {
                return result
            }
            let estimatedTypingDuration =
                Double(wordCount(for: record)) / Self.assumedTypingWordsPerMinute * 60
            return result + max(0, estimatedTypingDuration - duration)
        }

    }

    private func calculateCurrentStreak() -> Int {
        let activeDays = Set(records.map { calendar.startOfDay(for: $0.recordedAt) })
        guard !activeDays.isEmpty else {
            return 0
        }

        var date = calendar.startOfDay(for: Date())
        if !activeDays.contains(date),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: date),
           activeDays.contains(yesterday)
        {
            date = yesterday
        }

        var streak = 0
        while activeDays.contains(date) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else {
                break
            }
            date = previous
        }
        return streak
    }

    func dailyUsage(days: Int, endingAt endDate: Date = Date()) -> [AudioDailyUsage] {
        let end = calendar.startOfDay(for: endDate)
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: end) else {
                return nil
            }
            let matching = records.filter {
                calendar.isDate($0.recordedAt, inSameDayAs: date)
            }
            return AudioDailyUsage(
                date: date,
                words: matching.reduce(0) { $0 + self.wordCount(for: $1) },
                sessions: matching.count
            )
        }
    }

    func modelUsage(since startDate: Date? = nil) -> [AudioModelUsage] {
        let transcribedRecords = records.filter { record in
            !record.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (startDate.map { record.recordedAt >= $0 } ?? true)
        }
        let grouped = Dictionary(grouping: transcribedRecords) { record in
            record.modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        return grouped.map { modelID, matchingRecords in
            let durations = matchingRecords.compactMap { record -> TimeInterval? in
                guard let duration = record.durationSeconds,
                      duration.isFinite,
                      duration >= 0
                else {
                    return nil
                }
                return duration
            }
            let dictations = matchingRecords.count {
                $0.resolvedKind == .dictation
            }
            return AudioModelUsage(
                modelID: modelID.isEmpty ? nil : modelID,
                transcriptions: matchingRecords.count,
                dictations: dictations,
                recordings: matchingRecords.count - dictations,
                words: matchingRecords.reduce(0) { $0 + wordCount(for: $1) },
                durationSeconds: durations.reduce(0, +),
                timedTranscriptions: durations.count,
                lastUsedAt: matchingRecords.map(\.recordedAt).max() ?? .distantPast
            )
        }
        .sorted { lhs, rhs in
            if lhs.transcriptions != rhs.transcriptions {
                return lhs.transcriptions > rhs.transcriptions
            }
            if lhs.words != rhs.words {
                return lhs.words > rhs.words
            }
            guard let lhsModelID = lhs.modelID else { return false }
            guard let rhsModelID = rhs.modelID else { return true }
            return lhsModelID.localizedCaseInsensitiveCompare(rhsModelID) == .orderedAscending
        }
    }

    func record(withID id: String) -> AudioTranscriptionRecord? {
        records.first { $0.id == id }
    }

    func upsertTranscription(
        recordingURL: URL,
        transcript: String,
        durationSeconds: TimeInterval?,
        modelID: String?,
        applicationName: String?,
        kind: AudioRecordKind? = nil,
        title: String? = nil,
        persistAudioReference: Bool = false,
        summary: String? = nil,
        preserveExistingSummary: Bool = true,
        diarization: AudioDiarization? = nil,
        recordedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        do {
            try saveTranscription(recordingURL: recordingURL, transcript: transcript,
                durationSeconds: durationSeconds, modelID: modelID, applicationName: applicationName,
                kind: kind, title: title, persistAudioReference: persistAudioReference, summary: summary,
                preserveExistingSummary: preserveExistingSummary, diarization: diarization,
                recordedAt: recordedAt, updatedAt: updatedAt)
        } catch {
            NSLog("Nativ could not save transcription: %@", error.localizedDescription)
        }
    }

    /// Publish the transcript and its speaker metadata only after their atomic
    /// write succeeds. Callers can safely start matching once this returns.
    func saveTranscription(
        recordingURL: URL,
        transcript: String,
        durationSeconds: TimeInterval?,
        modelID: String?,
        applicationName: String?,
        kind: AudioRecordKind? = nil,
        title: String? = nil,
        persistAudioReference: Bool = false,
        summary: String? = nil,
        preserveExistingSummary: Bool = true,
        diarization: AudioDiarization? = nil,
        recordedAt: Date? = nil,
        updatedAt: Date = Date()
    ) throws {
        let id = recordingURL.deletingPathExtension().lastPathComponent
        let existing = record(withID: id)
        var updatedRecords = records, updatedProfiles = speakerProfiles
        var resolvedDiarization = diarization
        // IDs are local to a diarization run. Preserve identity only when its
        // complete segmentation is unchanged; never guess after re-diarizing.
        if let old = existing?.diarization, var new = resolvedDiarization,
           old.hasSameSegmentation(as: new) {
            new.speakerNames = old.speakerNames
            new.speakerProfileIDs = old.speakerProfileIDs
            new.speakerSuggestions = old.speakerSuggestions
            new.dismissedSpeakerSuggestions = old.dismissedSpeakerSuggestions
            resolvedDiarization = new
        } else {
            Self.removeVoiceSamples(for: id, records: &updatedRecords, profiles: &updatedProfiles)
        }
        let resolvedRecordedAt = existing?.recordedAt
            ?? recordedAt
            ?? Self.fileDate(for: recordingURL)
            ?? updatedAt
        let record = AudioTranscriptionRecord(
            id: id,
            recordedAt: resolvedRecordedAt,
            updatedAt: updatedAt,
            durationSeconds: durationSeconds ?? existing?.durationSeconds,
            transcript: transcript,
            modelID: modelID ?? existing?.modelID,
            applicationName: applicationName ?? existing?.applicationName,
            kind: kind ?? existing?.kind,
            title: title ?? existing?.title,
            audioFileName: persistAudioReference
                ? recordingURL.lastPathComponent
                : existing?.audioFileName,
            summary: summary ?? (preserveExistingSummary ? existing?.summary : nil),
            diarization: resolvedDiarization
        )
        updatedRecords.removeAll { $0.id == id }
        updatedRecords.append(record)
        updatedRecords.sort { $0.recordedAt > $1.recordedAt }
        try persist(records: updatedRecords, profiles: updatedProfiles)
        records = updatedRecords
        speakerProfiles = updatedProfiles
        rebuildDerivedMetrics()
    }

    func addCapture(
        recordingURL: URL,
        kind: AudioRecordKind,
        title: String,
        durationSeconds: TimeInterval?,
        recordedAt: Date? = nil
    ) {
        upsertTranscription(
            recordingURL: recordingURL,
            transcript: "",
            durationSeconds: durationSeconds,
            modelID: nil,
            applicationName: nil,
            kind: kind,
            title: title,
            persistAudioReference: true,
            recordedAt: recordedAt
        )
    }

    func updateSummary(_ summary: String, for recordID: String) {
        guard let existing = record(withID: recordID) else {
            return
        }
        let record = AudioTranscriptionRecord(
            id: existing.id,
            recordedAt: existing.recordedAt,
            updatedAt: Date(),
            durationSeconds: existing.durationSeconds,
            transcript: existing.transcript,
            modelID: existing.modelID,
            applicationName: existing.applicationName,
            kind: existing.kind,
            title: existing.title,
            audioFileName: existing.audioFileName,
            summary: summary,
            diarization: existing.diarization
        )
        records.removeAll { $0.id == recordID }
        records.append(record)
        records.sort { $0.recordedAt > $1.recordedAt }
        rebuildDerivedMetrics()
        save()
    }

    func updateTitle(_ title: String, for recordID: String) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              let existing = record(withID: recordID)
        else {
            return
        }
        let record = AudioTranscriptionRecord(
            id: existing.id,
            recordedAt: existing.recordedAt,
            updatedAt: Date(),
            durationSeconds: existing.durationSeconds,
            transcript: existing.transcript,
            modelID: existing.modelID,
            applicationName: existing.applicationName,
            kind: existing.kind,
            title: normalizedTitle,
            audioFileName: existing.audioFileName,
            summary: existing.summary,
            diarization: existing.diarization
        )
        records.removeAll { $0.id == recordID }
        records.append(record)
        records.sort { $0.recordedAt > $1.recordedAt }
        rebuildDerivedMetrics()
        save()
    }

    func updateSpeakerName(_ name: String, speakerID: Int, for recordID: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              var diarization = records[index].diarization,
              diarization.speakerIDs.contains(speakerID),
              diarization.speakerProfileIDs?[String(speakerID)] == nil else { return }
        let normalized = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var names = diarization.speakerNames ?? [:]
        names[String(speakerID)] = normalized.isEmpty ? nil : String(normalized.prefix(80))
        diarization.speakerNames = names.isEmpty ? nil : names
        // Persist recovered timings when editing a legacy recording.
        if diarization.transcriptSegments == nil, !diarization.resolvedTranscriptSegments.isEmpty {
            diarization.transcriptSegments = diarization.resolvedTranscriptSegments
        }
        records[index].diarization = diarization
        save()
    }

    func removeRecord(withID recordID: String) {
        guard records.contains(where: { $0.id == recordID }) else {
            return
        }
        records.removeAll { $0.id == recordID }
        removeVoiceSamples(for: recordID)
        rebuildDerivedMetrics()
        save()
    }

    func deleteDictation(
        withID recordID: String,
        recordingsDirectory: URL?,
        fileManager: FileManager = .default
    ) {
        guard records.contains(where: {
            $0.id == recordID && $0.resolvedKind == .dictation
        }) else {
            return
        }
        if let recordingsDirectory {
            Self.deleteDictationFiles(
                withID: recordID,
                in: recordingsDirectory,
                fileManager: fileManager
            )
        }
        records.removeAll { $0.id == recordID }
        save()
    }

    func deleteAllDictations(
        recordingsDirectory: URL?,
        fileManager: FileManager = .default
    ) {
        let recordIDs = records.compactMap { record in
            record.resolvedKind == .dictation ? record.id : nil
        }
        guard !recordIDs.isEmpty else {
            return
        }
        if let recordingsDirectory {
            for recordID in recordIDs {
                Self.deleteDictationFiles(
                    withID: recordID,
                    in: recordingsDirectory,
                    fileManager: fileManager
                )
            }
        }
        records.removeAll { $0.resolvedKind == .dictation }
        save()
    }

    func importTranscripts(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .creationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var changed = false
        for url in urls where
            url.pathExtension.localizedCaseInsensitiveCompare("txt") == .orderedSame
        {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  let transcript = try? String(contentsOf: url, encoding: .utf8)
            else {
                continue
            }
            let id = url.deletingPathExtension().lastPathComponent
            guard !records.contains(where: { $0.id == id }) else {
                continue
            }
            records.append(
                AudioTranscriptionRecord(
                    id: id,
                    recordedAt: Self.fileDate(for: url) ?? Date(),
                    updatedAt: Self.fileDate(for: url) ?? Date(),
                    durationSeconds: nil,
                    transcript: transcript,
                    modelID: nil,
                    applicationName: nil,
                    kind: nil,
                    title: nil,
                    audioFileName: nil,
                    summary: nil
                )
            )
            changed = true
        }
        guard changed else {
            return
        }
        records.sort { $0.recordedAt > $1.recordedAt }
        rebuildDerivedMetrics()
        save()
    }

    nonisolated static func wordCount(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isNewline
        }.count
    }

    private static var defaultStorageURL: URL {
        let applicationSupport =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ))
            ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("Voice Analytics.json")
    }

    private static func fileDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .creationDateKey]
        )
        return values?.contentModificationDate ?? values?.creationDate
    }

    private static func importedAt(from audioFileName: String?) -> Date? {
        let prefix = "Imported Audio "
        guard let audioFileName,
              audioFileName.hasPrefix(prefix)
        else {
            return nil
        }

        let timestamp = String(audioFileName.dropFirst(prefix.count).prefix(26))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.date(from: timestamp)
    }

    private static func replacingRecordedAt(
        _ recordedAt: Date,
        in record: AudioTranscriptionRecord
    ) -> AudioTranscriptionRecord {
        AudioTranscriptionRecord(
            id: record.id,
            recordedAt: recordedAt,
            updatedAt: record.updatedAt,
            durationSeconds: record.durationSeconds,
            transcript: record.transcript,
            modelID: record.modelID,
            applicationName: record.applicationName,
            kind: record.kind,
            title: record.title,
            audioFileName: record.audioFileName,
            summary: record.summary,
            diarization: record.diarization
        )
    }

    private static func deleteDictationFiles(
        withID recordID: String,
        in directory: URL,
        fileManager: FileManager
    ) {
        for pathExtension in ["txt", "wav"] {
            let url = directory
                .appendingPathComponent(recordID)
                .appendingPathExtension(pathExtension)
            try? fileManager.removeItem(at: url)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        let decoded: [AudioTranscriptionRecord]
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            if let legacy = try? decoder.decode([AudioTranscriptionRecord].self, from: data) {
                decoded = legacy
            } else {
                let storage = try decoder.decode(Storage.self, from: data)
                guard storage.version == 1 else { throw AudioSpeakerProfileError.unsupportedStorage }
                decoded = storage.records
                speakerProfiles = storage.speakerProfiles
            }
        } catch {
            storageReadFailed = true
            NSLog("Nativ could not read voice analytics: %@", error.localizedDescription)
            return
        }
        var migratedImportedDates = false
        records = decoded.map { record in
            guard let importedAt = Self.importedAt(from: record.audioFileName),
                  importedAt != record.recordedAt
            else {
                return record
            }
            migratedImportedDates = true
            return Self.replacingRecordedAt(importedAt, in: record)
        }
        .sorted { $0.recordedAt > $1.recordedAt }
        // Reuse only the current encoder or its byte-identical upstream copy.
        // Preserve opt-in and confirmed identities across actual encoder changes.
        let profilesBeforeMigration = speakerProfiles
        for index in speakerProfiles.indices {
            let samples = (speakerProfiles[index].voiceSamples ?? []).filter {
                speakerProfiles[index].voiceMatchingEnabled && (try? $0.embedding.validate()) != nil
            }
            speakerProfiles[index].voiceSamples = samples.isEmpty ? nil : samples
        }
        let recordsBeforeMigration = records
        records = Self.validatingSuggestions(in: records, profiles: speakerProfiles)
        rebuildDerivedMetrics()
        if migratedImportedDates || profilesBeforeMigration != speakerProfiles || recordsBeforeMigration != records {
            save()
        }
    }

    private func save() {
        do {
            try persist(records: records, profiles: speakerProfiles)
        } catch {
            NSLog("Nativ could not save voice analytics: %@", error.localizedDescription)
        }
    }

    private func persist(records: [AudioTranscriptionRecord], profiles: [AudioSpeakerProfile]) throws {
        guard !storageReadFailed else { throw AudioSpeakerProfileError.unsupportedStorage }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Storage(version: 1, records: records, speakerProfiles: profiles))
        try data.write(to: storageURL, options: .atomic)
    }

    private func commitSpeakerChanges(records: [AudioTranscriptionRecord], profiles: [AudioSpeakerProfile]) throws {
        let updated = Self.validatingSuggestions(in: records, profiles: profiles)
        let sortedProfiles = profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard updated != self.records || sortedProfiles != speakerProfiles else { return }
        try persist(records: updated, profiles: sortedProfiles)
        self.records = updated
        speakerProfiles = sortedProfiles
    }

    private static func validatingSuggestions(in records: [AudioTranscriptionRecord], profiles: [AudioSpeakerProfile]) -> [AudioTranscriptionRecord] {
        let activeIDs = Set(profiles.filter { $0.voiceMatchingEnabled && $0.hasCurrentVoiceSample }.map(\.id))
        return records.map { record in
            var result = record
            let suggestions = record.diarization?.speakerSuggestions?.filter {
                activeIDs.contains($0.value.profileID) && $0.value.usesCurrentVoiceModel
            }
            result.diarization?.speakerSuggestions = suggestions?.isEmpty == true ? nil : suggestions
            return result
        }
    }

    private func removeVoiceSamples(for recordID: String) {
        var updatedRecords = records, updatedProfiles = speakerProfiles
        Self.removeVoiceSamples(for: recordID, records: &updatedRecords, profiles: &updatedProfiles)
        records = updatedRecords
        speakerProfiles = updatedProfiles
    }

    private static func removeVoiceSamples(for recordID: String, records: inout [AudioTranscriptionRecord],
                                           profiles: inout [AudioSpeakerProfile]) {
        var changedProfiles = Set<String>()
        for index in profiles.indices {
            if profiles[index].voiceSamples?.contains(where: { $0.recordID == recordID }) == true {
                changedProfiles.insert(profiles[index].id)
            }
            profiles[index].voiceSamples?.removeAll { $0.recordID == recordID }
            if profiles[index].voiceSamples?.isEmpty == true {
                profiles[index].voiceMatchingEnabled = false
            }
        }
        records = Self.clearingSuggestions(in: records, profileIDs: changedProfiles)
    }

    private static func clearingSuggestions(in records: [AudioTranscriptionRecord], profileIDs: Set<String>) -> [AudioTranscriptionRecord] {
        guard !profileIDs.isEmpty else { return records }
        return records.map { record in
            var result = record
            result.diarization?.speakerSuggestions = record.diarization?.speakerSuggestions?
                .filter { !profileIDs.contains($0.value.profileID) }
            return result
        }
    }

    func profile(withID id: String) -> AudioSpeakerProfile? { speakerProfiles.first { $0.id == id } }

    func profileID(speakerID: Int, recordID: String) -> String? {
        guard let id = record(withID: recordID)?.diarization?.speakerProfileIDs?[String(speakerID)],
              profile(withID: id) != nil else { return nil }
        return id
    }

    func records(linkedToProfileID id: String) -> [AudioTranscriptionRecord] {
        records.filter { $0.diarization?.speakerProfileIDs?.values.contains(id) == true }
    }

    var speakerReviewItems: [AudioSpeakerReviewItem] {
        if let cachedSpeakerReviewItems { return cachedSpeakerReviewItems }
        var result: [AudioSpeakerReviewItem] = [], seen = Set<String>()
        for record in records.sorted(by: { $0.recordedAt == $1.recordedAt ? $0.id < $1.id : $0.recordedAt > $1.recordedAt }) {
            guard record.resolvedKind == .meeting,
                  let diarization = record.diarization, diarization.hasCompletedTranscription,
                  let chunks = try? diarization.transcriptionChunks(maximumDuration: 10),
                  let fingerprint = try? AudioSpeakerReviewUndo.segmentationFingerprint(diarization) else { continue }
            let soloChunks = Dictionary(grouping: chunks.filter { $0.speakers.count == 1 }, by: { $0.speakers[0] })
            let soloTranscript = Dictionary(grouping: diarization.resolvedTranscriptSegments.filter { $0.speakers.count == 1 }, by: { $0.speakers[0] })
            for speakerID in diarization.speakerIDs where diarization.speakerProfileIDs?[String(speakerID)] == nil {
                let turns = soloChunks[speakerID] ?? []
                // Match the extractor's 3 seconds plus 150 ms trim on each
                // side, using the same PCM grid without repartitioning a call.
                let hasUsableSpeech = turns.contains { ($0.end * 16000).rounded() - ($0.start * 16000).rounded() >= 52800 }
                let dismissed = diarization.dismissedSpeakerSuggestions?[String(speakerID)] ?? []
                let candidate = diarization.speakerSuggestions?[String(speakerID)]
                let profile = candidate.flatMap { self.profile(withID: $0.profileID) }
                let suggestion: AudioSpeakerSuggestion?
                if hasUsableSpeech, let candidate, let profile,
                   candidate.usesCurrentVoiceModel, candidate.similarity >= AudioSpeakerMatcher.minimumSimilarity,
                   !dismissed.contains(candidate.profileID), profile.voiceMatchingEnabled,
                   (profile.voiceSamples ?? []).contains(where: {
                       $0.recordID != record.id && (try? $0.embedding.validate()) != nil
                           && self.voiceEmbedding(recordID: $0.recordID, speakerID: $0.speakerID, profileID: profile.id) != nil
                   }) {
                    suggestion = candidate
                } else { suggestion = nil }
                let excerpt = AudioSpeakerReviewExcerpt.best(in: turns)
                let item = AudioSpeakerReviewItem(recordID: record.id, speakerID: speakerID,
                    recordingTitle: record.displayTitle, recordedAt: record.recordedAt,
                    speakerName: diarization.speakerName(speakerID),
                    reason: !hasUsableSpeech ? .insufficientSpeech : suggestion == nil ? .noMatch : .possibleMatch,
                    suggestion: suggestion, suggestedProfileName: suggestion == nil ? nil : profile?.name,
                    excerpt: excerpt,
                    transcriptQuote: AudioSpeakerReviewExcerpt.transcriptQuote(in: soloTranscript[speakerID] ?? [], excerpt: excerpt),
                    soloSpeechDuration: turns.reduce(0) { $0 + $1.end - $1.start }, segmentationFingerprint: fingerprint)
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        cachedSpeakerReviewItems = result
        return result
    }

    func linkSpeakerForReview(speakerID: Int, recordID: String, profileID: String,
                               expectedFingerprint: Data? = nil) throws -> AudioSpeakerReviewUndo {
        let before = try reviewTarget(recordID: recordID, speakerID: speakerID, expectedFingerprint: expectedFingerprint)
        let profilesBefore = speakerProfiles
        try linkSpeaker(speakerID: speakerID, recordID: recordID, profileID: profileID, expectedDiarization: before)
        return try reviewUndo(recordID: recordID, speakerID: speakerID, linkedProfileID: profileID,
                              before: before, profilesBefore: profilesBefore, createdProfile: nil)
    }

    func createAndLinkSpeakerForReview(name: String, speakerID: Int, recordID: String,
                                       expectedFingerprint: Data? = nil) throws -> AudioSpeakerReviewUndo {
        let before = try reviewTarget(recordID: recordID, speakerID: speakerID, expectedFingerprint: expectedFingerprint)
        let profilesBefore = speakerProfiles
        let profile = try createAndLinkSpeakerProfile(name: name, speakerID: speakerID, recordID: recordID)
        return try reviewUndo(recordID: recordID, speakerID: speakerID, linkedProfileID: profile.id,
                              before: before, profilesBefore: profilesBefore, createdProfile: profile)
    }

    private func reviewTarget(recordID: String, speakerID: Int, expectedFingerprint: Data?) throws -> AudioDiarization {
        guard let diarization = record(withID: recordID)?.diarization,
              diarization.speakerIDs.contains(speakerID) else { throw AudioSpeakerProfileError.missingSpeaker }
        guard diarization.hasCompletedTranscription else { throw AudioSpeakerProfileError.transcriptionRequired }
        if let expectedFingerprint {
            guard try AudioSpeakerReviewUndo.segmentationFingerprint(diarization) == expectedFingerprint,
                  diarization.speakerProfileIDs?[String(speakerID)] == nil else { throw AudioSpeakerProfileError.recordingChanged }
        }
        return diarization
    }

    private func reviewUndo(recordID: String, speakerID: Int, linkedProfileID: String,
                            before: AudioDiarization, profilesBefore: [AudioSpeakerProfile],
                            createdProfile: AudioSpeakerProfile?) throws -> AudioSpeakerReviewUndo {
        guard let after = record(withID: recordID)?.diarization else { throw AudioSpeakerReviewUndoError.changed }
        let changes = try profilesBefore.compactMap { profile -> AudioSpeakerReviewUndo.VoiceChange? in
            guard let current = self.profile(withID: profile.id) else { throw AudioSpeakerReviewUndoError.changed }
            let removed = (profile.voiceSamples ?? []).filter {
                $0.recordID == recordID && $0.speakerID == speakerID && !(current.voiceSamples ?? []).contains($0)
            }
            guard !removed.isEmpty else { return nil }
            return .init(profileID: profile.id, removedSamples: removed, wasEnabled: profile.voiceMatchingEnabled,
                         expectedFingerprint: try AudioSpeakerReviewUndo.voiceFingerprint(current))
        }
        var undo = AudioSpeakerReviewUndo(recordID: recordID, speakerID: speakerID, linkedProfileID: linkedProfileID,
            segmentationFingerprint: try AudioSpeakerReviewUndo.segmentationFingerprint(before),
            before: .init(before, speakerID: speakerID), after: .init(after, speakerID: speakerID), voiceChanges: changes,
            expectedSlotSamples: AudioSpeakerReviewUndo.slotSamples(speakerProfiles, recordID: recordID, speakerID: speakerID),
            createdProfile: createdProfile)
        if before.segments != after.segments {
            let voices = try profilesBefore.compactMap { profile -> AudioSpeakerReviewUndo.MergedVoice? in
                guard let current = self.profile(withID: profile.id) else { throw AudioSpeakerReviewUndoError.changed }
                guard profile.id == linkedProfileID || profile.voiceSamples != current.voiceSamples
                    || profile.voiceMatchingEnabled != current.voiceMatchingEnabled else { return nil }
                return .init(profileID: profile.id, beforeSamples: profile.voiceSamples,
                    wasEnabled: profile.voiceMatchingEnabled,
                    expectedFingerprint: try AudioSpeakerReviewUndo.voiceFingerprint(current))
            }
            undo.merge = .init(before: before, after: after, voices: voices)
        }
        return undo
    }

    func undoSpeakerReview(_ undo: AudioSpeakerReviewUndo) throws {
        if let merge = undo.merge {
            try undoSpeakerMerge(merge, recordID: undo.recordID)
            return
        }
        guard let index = records.firstIndex(where: { $0.id == undo.recordID }),
              var diarization = records[index].diarization,
              try AudioSpeakerReviewUndo.segmentationFingerprint(diarization) == undo.segmentationFingerprint,
              AudioSpeakerReviewUndo.Slot(diarization, speakerID: undo.speakerID) == undo.after,
              AudioSpeakerReviewUndo.slotSamples(speakerProfiles, recordID: undo.recordID, speakerID: undo.speakerID) == undo.expectedSlotSamples
        else { throw AudioSpeakerReviewUndoError.changed }
        if let previousID = undo.before.profileID, profile(withID: previousID) == nil { throw AudioSpeakerReviewUndoError.changed }
        var profiles = speakerProfiles
        for change in undo.voiceChanges {
            guard let profileIndex = profiles.firstIndex(where: { $0.id == change.profileID }),
                  try AudioSpeakerReviewUndo.voiceFingerprint(profiles[profileIndex]) == change.expectedFingerprint,
                  change.removedSamples.allSatisfy({ (try? $0.embedding.validate()) != nil })
            else { throw AudioSpeakerReviewUndoError.changed }
            profiles[profileIndex].voiceSamples = (profiles[profileIndex].voiceSamples ?? []) + change.removedSamples
            profiles[profileIndex].voiceMatchingEnabled = change.wasEnabled
        }
        let slot = String(undo.speakerID)
        var links = diarization.speakerProfileIDs ?? [:], names = diarization.speakerNames ?? [:]
        var suggestions = diarization.speakerSuggestions ?? [:], dismissed = diarization.dismissedSpeakerSuggestions ?? [:]
        links[slot] = undo.before.profileID
        names[slot] = undo.before.profileID.flatMap { profile(withID: $0)?.name } ?? undo.before.name
        suggestions[slot] = undo.before.suggestion
        dismissed[slot] = undo.before.dismissed
        diarization.speakerProfileIDs = links.isEmpty ? nil : links
        diarization.speakerNames = names.isEmpty ? nil : names
        diarization.speakerSuggestions = suggestions.isEmpty ? nil : suggestions
        diarization.dismissedSpeakerSuggestions = dismissed.isEmpty ? nil : dismissed
        var updated = records
        updated[index].diarization = diarization
        if let created = undo.createdProfile,
           profiles.first(where: { $0.id == created.id }) == created,
           !updated.contains(where: { $0.diarization?.speakerProfileIDs?.values.contains(created.id) == true }) {
            profiles.removeAll { $0.id == created.id }
        }
        try commitSpeakerChanges(records: updated, profiles: profiles)
    }

    private func undoSpeakerMerge(_ merge: AudioSpeakerReviewUndo.Merge, recordID: String) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].diarization == merge.after,
              (merge.before.speakerProfileIDs ?? [:]).values.allSatisfy({ profile(withID: $0) != nil })
        else { throw AudioSpeakerReviewUndoError.changed }
        var profiles = speakerProfiles
        for voice in merge.voices {
            guard let i = profiles.firstIndex(where: { $0.id == voice.profileID }),
                  try AudioSpeakerReviewUndo.voiceFingerprint(profiles[i]) == voice.expectedFingerprint
            else { throw AudioSpeakerReviewUndoError.changed }
            profiles[i].voiceSamples = voice.beforeSamples
            profiles[i].voiceMatchingEnabled = voice.wasEnabled
        }
        var updated = records
        var restored = merge.before
        for (slot, profileID) in restored.speakerProfileIDs ?? [:] {
            restored.speakerNames?[slot] = profile(withID: profileID)?.name
        }
        updated[index].diarization = restored
        try commitSpeakerChanges(records: updated, profiles: profiles)
    }

    /// Reuse only a sample whose identity is still confirmed and whose encoder
    /// revision is current. Opt-out and regeneration remove these samples.
    func voiceEmbedding(recordID: String, speakerID: Int, profileID: String? = nil) -> SpeakerVoiceEmbedding? {
        guard let linkedID = self.profileID(speakerID: speakerID, recordID: recordID),
              profileID == nil || profileID == linkedID,
              let profile = profile(withID: linkedID), profile.voiceMatchingEnabled,
              record(withID: recordID)?.diarization?.speakerIDs.contains(speakerID) == true else { return nil }
        return profile.voiceSamples?.first {
            $0.recordID == recordID && $0.speakerID == speakerID && (try? $0.embedding.validate()) != nil
        }?.embedding
    }

    private static func profileName(_ name: String) throws -> String {
        let value = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AudioSpeakerProfileError.emptyName }
        return String(value.prefix(80))
    }

    @discardableResult
    func createSpeakerProfile(name: String) throws -> AudioSpeakerProfile {
        let profile = AudioSpeakerProfile(id: UUID().uuidString, name: try Self.profileName(name),
                                          createdAt: Date(), updatedAt: Date())
        try commitSpeakerChanges(records: records, profiles: speakerProfiles + [profile])
        return profile
    }

    @discardableResult
    func createAndLinkSpeakerProfile(name: String, speakerID: Int, recordID: String) throws -> AudioSpeakerProfile {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              var diarization = records[index].diarization,
              diarization.speakerIDs.contains(speakerID) else { throw AudioSpeakerProfileError.missingSpeaker }
        let profile = AudioSpeakerProfile(id: UUID().uuidString, name: try Self.profileName(name),
                                          createdAt: Date(), updatedAt: Date())
        var updated = records, profiles = speakerProfiles
        var changedProfiles = Set<String>()
        for i in profiles.indices {
            if profiles[i].voiceSamples?.contains(where: { $0.recordID == recordID && $0.speakerID == speakerID }) == true {
                changedProfiles.insert(profiles[i].id)
                profiles[i].voiceSamples?.removeAll { $0.recordID == recordID && $0.speakerID == speakerID }
                if profiles[i].voiceSamples?.isEmpty == true { profiles[i].voiceMatchingEnabled = false }
            }
        }
        diarization.setProfile(profile, for: speakerID)
        updated[index].diarization = diarization
        profiles.append(profile)
        updated = Self.clearingSuggestions(in: updated, profileIDs: changedProfiles)
        try commitSpeakerChanges(records: updated, profiles: profiles)
        return profile
    }

    /// Create the first confirmed voice sample and its recording link together.
    /// A concurrent manual link wins over an automatic result from older audio.
    @discardableResult
    func createVoiceProfile(embedding: SpeakerVoiceEmbedding, speakerID: Int, recordID: String,
                            expectedDiarization: AudioDiarization) throws -> AudioSpeakerProfile {
        try embedding.validate()
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              var diarization = records[index].diarization,
              diarization.hasSameSegmentation(as: expectedDiarization),
              diarization.speakerIDs.contains(speakerID), diarization.speakerProfileIDs?[String(speakerID)] == nil
        else { throw AudioSpeakerProfileError.recordingChanged }
        let slot = String(speakerID)
        let name: String
        if let localName = diarization.speakerNames?[slot],
           !localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = try Self.profileName(localName)
        } else {
            let existingNames = Set(speakerProfiles.map { $0.name.lowercased() })
            var suffix = 1
            while existingNames.contains("unnamed speaker \(suffix)") { suffix += 1 }
            name = "Unnamed speaker \(suffix)"
        }
        let now = Date()
        let profile = AudioSpeakerProfile(id: UUID().uuidString, name: name, createdAt: now, updatedAt: now,
            voiceMatchingEnabled: true, voiceSamples: [
                .init(recordID: recordID, speakerID: speakerID, embedding: embedding),
            ])
        diarization.setProfile(profile, for: speakerID)
        var updated = records
        updated[index].diarization = diarization
        try commitSpeakerChanges(records: updated, profiles: speakerProfiles + [profile])
        return profile
    }

    func renameSpeakerProfile(id: String, name: String) throws {
        guard let index = speakerProfiles.firstIndex(where: { $0.id == id }) else {
            throw AudioSpeakerProfileError.missingProfile
        }
        let normalizedName = try Self.profileName(name)
        guard speakerProfiles[index].name != normalizedName else { return }
        var profiles = speakerProfiles, updated = records
        profiles[index].name = normalizedName
        profiles[index].updatedAt = Date()
        for recordIndex in updated.indices {
            guard var diarization = updated[recordIndex].diarization else { continue }
            for (slot, profileID) in diarization.speakerProfileIDs ?? [:] where profileID == id {
                var names = diarization.speakerNames ?? [:]
                names[slot] = profiles[index].name
                diarization.speakerNames = names
            }
            updated[recordIndex].diarization = diarization
        }
        try commitSpeakerChanges(records: updated, profiles: profiles)
    }

    @discardableResult
    func linkSpeaker(speakerID: Int, recordID: String, profileID: String?,
                     expectedDiarization: AudioDiarization? = nil) throws -> Int {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              var diarization = records[index].diarization,
              diarization.speakerIDs.contains(speakerID) else { throw AudioSpeakerProfileError.missingSpeaker }
        if let expectedDiarization {
            let slot = String(speakerID)
            guard diarization.hasSameSegmentation(as: expectedDiarization),
                  diarization.speakerProfileIDs?[slot] == expectedDiarization.speakerProfileIDs?[slot],
                  diarization.speakerNames?[slot] == expectedDiarization.speakerNames?[slot]
            else { throw AudioSpeakerProfileError.recordingChanged }
        }
        let profile = profileID.flatMap { self.profile(withID: $0) }
        guard profileID == nil || profile != nil else { throw AudioSpeakerProfileError.missingProfile }
        let existing = profileID.map { id in
            diarization.speakerIDs.filter { $0 != speakerID && diarization.speakerProfileIDs?[String($0)] == id }
        } ?? []
        let target = existing.first ?? speakerID
        if let profileID, diarization.speakerProfileIDs?[String(speakerID)] == profileID, existing.isEmpty { return speakerID }
        var updated = records, profiles = speakerProfiles
        var changedProfiles = Set<String>()
        // A corrected label must never keep training the previous person's voice.
        for i in profiles.indices {
            if profiles[i].id == profileID { continue }
            if profiles[i].voiceSamples?.contains(where: { $0.recordID == recordID && $0.speakerID == speakerID }) == true {
                changedProfiles.insert(profiles[i].id)
            }
            profiles[i].voiceSamples?.removeAll { $0.recordID == recordID && $0.speakerID == speakerID }
            if profiles[i].voiceSamples?.isEmpty == true { profiles[i].voiceMatchingEnabled = false }
        }
        let slot = String(speakerID)
        if let previousProfileID = diarization.speakerProfileIDs?[slot], previousProfileID != profileID {
            var dismissed = diarization.dismissedSpeakerSuggestions ?? [:]
            if !dismissed[slot, default: []].contains(previousProfileID) {
                dismissed[slot, default: []].append(previousProfileID)
            }
            diarization.dismissedSpeakerSuggestions = dismissed
        }
        if let suggestion = diarization.speakerSuggestions?[slot], suggestion.profileID != profileID {
            var dismissed = diarization.dismissedSpeakerSuggestions ?? [:]
            dismissed[slot, default: []].append(suggestion.profileID)
            diarization.dismissedSpeakerSuggestions = dismissed
        }
        diarization.setProfile(profile, for: speakerID)
        if !existing.isEmpty, let profileID {
            let mergedIDs = Set(existing + [speakerID])
            diarization = try diarization.mergingSpeakers(mergedIDs, into: target)
            diarization.speakerNames?[String(target)] = profile?.name
            for i in profiles.indices {
                let previousSamples = profiles[i].voiceSamples
                let candidates = (previousSamples ?? []).filter {
                    $0.recordID == recordID && mergedIDs.contains($0.speakerID)
                }
                guard !candidates.isEmpty else { continue }
                profiles[i].voiceSamples?.removeAll {
                    $0.recordID == recordID && mergedIDs.contains($0.speakerID)
                }
                if profiles[i].id == profileID {
                    // Reuse an existing valid embedding; a merge needs no new
                    // model run and must not store duplicate samples for an ID.
                    let valid = candidates.filter { (try? $0.embedding.validate()) != nil }
                    if let sample = valid.first(where: { $0.speakerID == target }) ?? valid.first
                        ?? candidates.first(where: { $0.speakerID == target }) ?? candidates.first {
                        profiles[i].voiceSamples?.append(.init(recordID: recordID, speakerID: target, embedding: sample.embedding))
                    }
                }
                if profiles[i].voiceSamples?.isEmpty == true { profiles[i].voiceMatchingEnabled = false }
                if profiles[i].voiceSamples != previousSamples { changedProfiles.insert(profiles[i].id) }
            }
        }
        updated[index].diarization = diarization
        updated = Self.clearingSuggestions(in: updated, profileIDs: changedProfiles)
        try commitSpeakerChanges(records: updated, profiles: profiles)
        return target
    }

    func deleteSpeakerProfile(id: String) throws {
        guard profile(withID: id) != nil else { throw AudioSpeakerProfileError.missingProfile }
        var updated = records
        for index in updated.indices {
            guard var diarization = updated[index].diarization else { continue }
            for (slot, linkedID) in diarization.speakerProfileIDs ?? [:] where linkedID == id {
                var dismissed = diarization.dismissedSpeakerSuggestions ?? [:]
                if !dismissed[slot, default: []].contains(id) { dismissed[slot, default: []].append(id) }
                diarization.dismissedSpeakerSuggestions = dismissed
                diarization.speakerProfileIDs?[slot] = nil
                // Keep the meeting's human-readable label after deleting a profile.
            }
            diarization.speakerSuggestions = diarization.speakerSuggestions?.filter { $0.value.profileID != id }
            updated[index].diarization = diarization
        }
        try commitSpeakerChanges(records: updated, profiles: speakerProfiles.filter { $0.id != id })
    }

    func setVoiceMatchingEnabled(_ enabled: Bool, profileID: String) throws {
        guard let index = speakerProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw AudioSpeakerProfileError.missingProfile
        }
        var profiles = speakerProfiles, updated = records
        if enabled && !profiles[index].hasCurrentVoiceSample { throw AudioSpeakerProfileError.noVoiceSample }
        if profiles[index].voiceMatchingEnabled == enabled,
           enabled || profiles[index].voiceSamples == nil { return }
        profiles[index].voiceMatchingEnabled = enabled
        if !enabled {
            profiles[index].voiceSamples = nil
            for i in updated.indices {
                let suggestions = updated[i].diarization?.speakerSuggestions?.filter { $0.value.profileID != profileID }
                updated[i].diarization?.speakerSuggestions = suggestions
            }
        }
        profiles[index].updatedAt = Date()
        try commitSpeakerChanges(records: updated, profiles: profiles)
    }

    func enrollVoice(_ embedding: SpeakerVoiceEmbedding, profileID: String, recordID: String,
                     speakerID: Int, expectedDiarization: AudioDiarization) throws {
        try embedding.validate()
        guard let index = speakerProfiles.firstIndex(where: { $0.id == profileID }) else {
            throw AudioSpeakerProfileError.missingProfile
        }
        guard let current = record(withID: recordID)?.diarization,
              current.hasSameSegmentation(as: expectedDiarization),
              current.speakerProfileIDs?[String(speakerID)] == profileID else {
            throw AudioSpeakerProfileError.recordingChanged
        }
        // A repeated backfill or matching pass must retain the first validated
        // sample instead of rewriting it with another extraction of the audio.
        if voiceEmbedding(recordID: recordID, speakerID: speakerID, profileID: profileID) != nil { return }
        var profiles = speakerProfiles
        var samples = (profiles[index].voiceSamples ?? []).filter { (try? $0.embedding.validate()) != nil }
        samples.removeAll { $0.recordID == recordID && $0.speakerID == speakerID }
        samples.append(AudioSpeakerVoiceSample(recordID: recordID, speakerID: speakerID, embedding: embedding))
        profiles[index].voiceSamples = Array(samples.suffix(5))
        profiles[index].voiceMatchingEnabled = true
        profiles[index].updatedAt = Date()
        try commitSpeakerChanges(records: records, profiles: profiles)
    }

    func dismissSpeakerSuggestion(speakerID: Int, recordID: String) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              var diarization = records[index].diarization else { throw AudioSpeakerProfileError.missingSpeaker }
        let slot = String(speakerID)
        if let suggestion = diarization.speakerSuggestions?[slot] {
            var dismissed = diarization.dismissedSpeakerSuggestions ?? [:]
            dismissed[slot, default: []].append(suggestion.profileID)
            diarization.dismissedSpeakerSuggestions = dismissed
        }
        diarization.speakerSuggestions?[slot] = nil
        var updated = records
        updated[index].diarization = diarization
        try commitSpeakerChanges(records: updated, profiles: speakerProfiles)
    }
}
