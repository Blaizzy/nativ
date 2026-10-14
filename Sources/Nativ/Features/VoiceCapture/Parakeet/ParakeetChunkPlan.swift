import Foundation

/// One fixed encoder shape: 30 seconds of features. At a full window, the
/// frontend's redundant trailing zero frame is replaced by convolution padding.
/// Four seconds of context on either side of a seam are encoded but discarded.
/// All boundaries align with the encoder's eight-frame subsampling lattice.
enum ParakeetChunkPlan {
    static let windowFrames = 3000
    static let contextFrames = 400
    static let subsampling = 8
    static let tensorFrames = windowFrames

    /// Host-computed lengths avoid integer division inside the FP16 encoder.
    static func subsampledLengths(validFrames: Int) -> [Float16] {
        [2, 4, 8].map { Float16((validFrames + $0 - 1) / $0) }
    }

    struct Window: Equatable, Sendable {
        let startFrame: Int
        let validFrames: Int
        let keptEncodedFrames: Range<Int>
    }

    static func windows(validFrames: Int) throws -> [Window] {
        guard validFrames >= 2 else { throw ParakeetError.tooShort }
        var windows = [Window]()
        var start = 0
        while start < validFrames {
            let length = min(windowFrames, validFrames - start)
            let isLast = start + length == validFrames
            let firstKept = start == 0 ? 0 : contextFrames / subsampling
            let lastKept = isLast
                ? (length + subsampling - 1) / subsampling
                : (windowFrames - contextFrames) / subsampling
            windows.append(Window(startFrame: start, validFrames: length, keptEncodedFrames: firstKept..<lastKept))
            if isLast { break }
            start += windowFrames - 2 * contextFrames
        }
        return windows
    }

    static func paddedFeatures(_ mel: ParakeetMel, window: Window) -> [Float] {
        let bins = ParakeetAudio.melBins
        var values = [Float](repeating: 0, count: tensorFrames * bins)
        let start = window.startFrame * bins
        let count = window.validFrames * bins
        values.replaceSubrange(0..<count, with: mel.values[start..<(start + count)])
        return values
    }
}
