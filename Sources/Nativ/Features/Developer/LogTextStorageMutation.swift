import Foundation

enum LogTextStorageMutation: Equatable {
    case replaceAll
    case replaceSuffix(fromUTF16Offset: Int)

    static func plan(
        previousText: String,
        previousQuery: String,
        newText: String,
        newQuery: String
    ) -> LogTextStorageMutation {
        guard previousQuery == newQuery,
              newText.utf16.starts(with: previousText.utf16)
        else {
            return .replaceAll
        }

        let previousNSString = previousText as NSString
        let lastNewline = previousNSString.range(
            of: "\n",
            options: .backwards
        )
        let offset = lastNewline.location == NSNotFound
            ? 0
            : NSMaxRange(lastNewline)
        return .replaceSuffix(fromUTF16Offset: offset)
    }
}
