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

    @Published private(set) var records: [AudioTranscriptionRecord] = []

    private let storageURL: URL
    private let calendar: Calendar
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

    func modelUsage() -> [AudioModelUsage] {
        let transcribedRecords = records.filter {
            !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        recordedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        let id = recordingURL.deletingPathExtension().lastPathComponent
        let existing = record(withID: id)
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
            summary: summary ?? existing?.summary
        )
        records.removeAll { $0.id == id }
        records.append(record)
        records.sort { $0.recordedAt > $1.recordedAt }
        rebuildDerivedMetrics()
        save()
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
            summary: summary
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
            summary: existing.summary
        )
        records.removeAll { $0.id == recordID }
        records.append(record)
        records.sort { $0.recordedAt > $1.recordedAt }
        rebuildDerivedMetrics()
        save()
    }

    func removeRecord(withID recordID: String) {
        guard records.contains(where: { $0.id == recordID }) else {
            return
        }
        records.removeAll { $0.id == recordID }
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
            summary: record.summary
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
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(
                [AudioTranscriptionRecord].self,
                from: data
              )
        else {
            records = []
            rebuildDerivedMetrics()
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
        rebuildDerivedMetrics()
        if migratedImportedDates {
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Nativ could not save voice analytics: %@", error.localizedDescription)
        }
    }
}
