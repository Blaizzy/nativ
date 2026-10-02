import Foundation

actor AudioTranscriptFileWriter {
    private let url: URL

    init(url: URL) throws {
        self.url = url
        try Data().write(to: url, options: .atomic)
    }

    func append(_ segment: String) throws {
        guard !segment.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(segment.utf8))
        try handle.synchronize()
    }

    func replace(with transcript: String) throws {
        try Data(transcript.utf8).write(to: url, options: .atomic)
    }
}
