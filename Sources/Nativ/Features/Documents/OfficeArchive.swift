import Foundation
import ZIPFoundation

enum OfficeArchive {
    private static let compressedLimit = 50 * 1_024 * 1_024
    private static let expandedLimit: UInt64 = 200 * 1_024 * 1_024
    private static let entryLimit = 10_000

    static func open(_ data: Data) throws -> Archive {
        guard data.count <= compressedLimit else {
            throw DocumentTextExtractionError.archiveTooLarge
        }

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentTextExtractionError.invalidDocument
        }

        var expandedBytes: UInt64 = 0
        for (offset, entry) in archive.enumerated() {
            guard offset < entryLimit,
                  entry.uncompressedSize <= expandedLimit - expandedBytes
            else {
                throw DocumentTextExtractionError.archiveTooLarge
            }
            expandedBytes += entry.uncompressedSize
        }
        return archive
    }
}
