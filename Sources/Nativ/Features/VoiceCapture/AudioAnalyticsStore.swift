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
        case .voiceNote:
            "Voice note"
        case .meeting:
            "Meeting"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation:
            "text.cursor"
        case .voiceNote:
            "mic.fill"
        case .meeting:
            "person.2.wave.2"
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

@MainActor
final class AudioAnalyticsStore: ObservableObject {
    static let shared = AudioAnalyticsStore()
    static let assumedTypingWordsPerMinute = 45.0

    @Published private(set) var records: [AudioTranscriptionRecord] = []

    private let storageURL: URL
    private let calendar: Calendar

    init(
        storageURL: URL? = nil,
        calendar: Calendar = .current
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.calendar = calendar
        load()
    }

    var totalWords: Int {
        records.reduce(0) { $0 + $1.wordCount }
    }

    var averageWordsPerMinute: Double? {
        let timed = records.compactMap { record -> (Int, TimeInterval)? in
            guard let duration = record.durationSeconds, duration > 0 else {
                return nil
            }
            return (record.wordCount, duration)
        }
        let duration = timed.reduce(0) { $0 + $1.1 }
        guard duration > 0 else {
            return nil
        }
        return Double(timed.reduce(0) { $0 + $1.0 }) / (duration / 60)
    }

    var estimatedTimeSaved: TimeInterval {
        records.reduce(0) { result, record in
            guard let duration = record.durationSeconds else {
                return result
            }
            let estimatedTypingDuration =
                Double(record.wordCount) / Self.assumedTypingWordsPerMinute * 60
            return result + max(0, estimatedTypingDuration - duration)
        }
    }

    var currentStreak: Int {
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
                words: matching.reduce(0) { $0 + $1.wordCount },
                sessions: matching.count
            )
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
        save()
    }

    func addCapture(
        recordingURL: URL,
        kind: AudioRecordKind,
        title: String,
        durationSeconds: TimeInterval?
    ) {
        upsertTranscription(
            recordingURL: recordingURL,
            transcript: "",
            durationSeconds: durationSeconds,
            modelID: nil,
            applicationName: nil,
            kind: kind,
            title: title,
            persistAudioReference: true
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
        save()
    }

    func removeRecord(withID recordID: String) {
        guard records.contains(where: { $0.id == recordID }) else {
            return
        }
        records.removeAll { $0.id == recordID }
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

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode(
                [AudioTranscriptionRecord].self,
                from: data
              )
        else {
            records = []
            return
        }
        records = decoded.sorted { $0.recordedAt > $1.recordedAt }
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
