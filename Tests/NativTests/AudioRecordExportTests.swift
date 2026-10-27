import AppKit
import PDFKit
import XCTest

final class AudioRecordExportTests: XCTestCase {
    func testExportsSpeakerLabelsWhileKeepingPlainTranscriptForAnalytics() throws {
        var record = record(transcript: "Hello there.")
        record.diarization = AudioDiarization(modelID: MeetingDiarizer.defaultModelID, revision: "test", segments: [
            .init(start: 0, end: 1, speaker: 0),
        ], speakerTranscript: "[00:00] Speaker 1: Hello there.")
        let data = try AudioRecordExport(record: record).data(format: .text)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(record.displayTranscript))
        XCTAssertEqual(record.transcript, "Hello there.")
        XCTAssertEqual(record.wordCount, 2)
    }

    func testTextExportsBothSectionsAndPreservesVerbatimText() throws {
        let record = record(transcript: "Speaker: **literal**\n\n  Zażółć  こんにちは\n", summary: "## Decision\nShip **Friday**.")
        let data = try AudioRecordExport(record: record).data(format: .text)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(record.displayTitle))
        XCTAssertTrue(text.contains("Recorded "))
        XCTAssertTrue(text.contains(record.transcript))
        XCTAssertTrue(text.contains(try XCTUnwrap(record.summary)))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Summary")).lowerBound,
                          try XCTUnwrap(text.range(of: "Transcript")).lowerBound)
    }

    func testExportRequiresBothSummaryAndTranscript() throws {
        XCTAssertTrue(AudioRecordExport(record: record()).isAvailable)
        let incompleteRecords = [
            record(summary: nil), record(summary: ""), record(summary: " \n\t"),
            record(transcript: ""), record(transcript: " \n\t"),
            record(transcript: "", summary: nil),
        ]
        for record in incompleteRecords {
            let export = AudioRecordExport(record: record)
            XCTAssertFalse(export.isAvailable)
            for format in AudioRecordExportFormat.allCases {
                XCTAssertThrowsError(try export.data(format: format))
            }
        }
    }

    func testDOCXRoundTripPreservesUnicodeAndFormatsSummary() throws {
        let record = record(
            transcript: "Speaker: Keep **literal markers**.\nZażółć gęślą jaźń — こんにちは",
            summary: "# Decisions\n\nShip **Friday** with *care*.\n\n- First action\n- Second action\n\n[Reference](https://example.com)")
        let data = try AudioRecordExport(record: record).data(format: .docx)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "DOCX must be an actual ZIP package")
        let document = try NSAttributedString(data: data, options: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
        ], documentAttributes: nil)
        XCTAssertTrue(document.string.contains(record.transcript))
        XCTAssertTrue(document.string.contains("Decisions"))
        XCTAssertTrue(document.string.contains("• First action"))
        XCTAssertFalse(document.string.contains("# Decisions"))
        XCTAssertFalse(document.string.contains("**Friday**"))
        let friday = (document.string as NSString).range(of: "Friday")
        let font = try XCTUnwrap(document.attribute(.font, at: friday.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(document.string.contains("Reference (https://example.com)"))
    }

    func testPDFPaginatesAnUnbrokenLongTranscriptWithoutLosingText() throws {
        let tokens = (0..<2200).map { String(format: "token%04d", $0) }
        let record = record(transcript: tokens.joined(separator: " "), summary: "## Decision\nApproved.")
        let data = try AudioRecordExport(record: record).data(format: .pdf)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 2)
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Approved."))
        let extracted = text.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("token") }
        XCTAssertEqual(extracted, tokens, "Every token should appear exactly once and in order across pages")
        let lastPage = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
        XCTAssertTrue(lastPage.contains("token2199"))
    }

    func testPDFPreservesUnicodeAndLiteralTranscriptMarkup() throws {
        let transcript = "Zażółć gęślą jaźń — こんにちは\nKeep **these** markers."
        let data = try AudioRecordExport(record: record(transcript: transcript)).data(format: .pdf)
        let text = try XCTUnwrap(PDFDocument(data: data)?.string)
        XCTAssertTrue(text.contains(transcript))
    }

    func testFilenamesAreSafeAndKeepTheRequestedExtension() {
        for title in ["../Planning: Q4/Review\\Notes\n", String(repeating: "🎙️", count: 200), " /:\n."] {
            for format in AudioRecordExportFormat.allCases {
                let filename = AudioRecordExport(record: record(title: title)).filename(for: format)
                XCTAssertFalse(filename.contains("/"))
                XCTAssertFalse(filename.contains("\\"))
                XCTAssertFalse(filename.contains(":"))
                XCTAssertFalse(filename.contains("\n"))
                XCTAssertFalse(filename.hasPrefix("."))
                XCTAssertLessThan(filename.utf8.count, 255)
                XCTAssertTrue(filename.hasSuffix(".\(format.rawValue)"))
            }
        }
    }

    func testWritesSelectedFormatAndReportsSaveFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let export = AudioRecordExport(record: record())
        for format in AudioRecordExportFormat.allCases {
            let url = directory.appendingPathComponent(export.filename(for: format))
            try await Task.detached {
                try export.write(to: url, format: format)
            }.value
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
        }
        XCTAssertThrowsError(try export.write(to: directory.appendingPathComponent("missing/file.txt"), format: .text))
    }

    private func record(
        transcript: String = "Original transcript", summary: String? = "Saved summary", title: String = "Planning meeting"
    ) -> AudioTranscriptionRecord {
        AudioTranscriptionRecord(
            id: "recording", recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 120,
            transcript: transcript, modelID: nil, applicationName: nil, kind: .meeting,
            title: title, audioFileName: nil, summary: summary)
    }
}
