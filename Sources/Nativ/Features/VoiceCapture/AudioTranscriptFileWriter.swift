import Foundation

actor AudioTranscriptFileWriter {
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try Data().write(to: url, options: .atomic)
    }

    func replace(with transcript: String) throws {
        try Data(transcript.utf8).write(to: url, options: .atomic)
    }
}
