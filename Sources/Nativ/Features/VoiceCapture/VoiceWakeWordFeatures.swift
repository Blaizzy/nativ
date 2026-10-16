import Accelerate
import Foundation

/// HN-2 log-mel contract; adapted from lucasnewman/wakewords at 799951a.
/// Scratch storage is owned by the inference worker, away from the audio callback.
final class VoiceWakeWordFeatures {
    static let sampleRate = 16_000
    static let windowSamples = 32_000
    static let melCount = 128
    static let frameCount = 200
    private let setup: vDSP_DFT_Setup
    private let hann: [Float]
    private let filters: [Float]
    private var inputReal = [Float](repeating: 0, count: 512)
    private let inputImaginary = [Float](repeating: 0, count: 512)
    private var outputReal = [Float](repeating: 0, count: 512)
    private var outputImaginary = [Float](repeating: 0, count: 512)
    private var power = [Float](repeating: 0, count: 257)
    private var melFrame = [Float](repeating: 0, count: 128)
    // Unnormalized mel frames in a ring. Normalization still covers each full window.
    private var cachedMels = [Float](repeating: 0, count: 128 * 200)
    private var cacheStart = 0
    private var previousWindowEnd: Int64?

    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD) else {
            throw VoiceWakeWordModelError.invalidModel("Could not create the Accelerate FFT.")
        }
        self.setup = setup
        let step = Float(2 * Double.pi / 400)
        hann = (0..<400).map { 0.5 - 0.5 * cosf(Float($0) * step) }
        filters = Self.makeSlaneyFilters()
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func compute(_ audio: [Float]) throws -> [Float] {
        var result = [Float](repeating: 0, count: Self.melCount * Self.frameCount)
        try result.withUnsafeMutableBufferPointer {
            try compute(audio, windowEnd: nil, into: $0.baseAddress!)
        }
        return result
    }

    func reset() {
        previousWindowEnd = nil
    }

    /// `windowEnd` is the exclusive sample offset in a continuous audio stream.
    /// Pass nil for unrelated windows; reset after any dropped or replaced audio.
    func compute(
        _ audio: [Float], windowEnd: Int64?, into output: UnsafeMutablePointer<Float>,
        melStride: Int = 200, frameStride: Int = 1
    ) throws {
        guard audio.count == Self.windowSamples, audio.allSatisfy(\.isFinite) else {
            reset()
            throw VoiceWakeWordModelError.invalidModel("Expected 32,000 finite mono samples at 16 kHz.")
        }
        var shift = Self.frameCount
        if let windowEnd, let previousWindowEnd, windowEnd > previousWindowEnd {
            let advance = windowEnd - previousWindowEnd
            if advance < Int64(Self.windowSamples), advance % 160 == 0 {
                shift = Int(advance / 160)
            }
        }
        cacheStart = (cacheStart + shift) % Self.frameCount
        previousWindowEnd = windowEnd
        for frame in 0..<Self.frameCount {
            // Frames 0 and 1 depend on left-edge zero padding. Old frame 199
            // contains right-edge padding, so it cannot be reused in the interior.
            if frame >= 2, frame + shift < Self.frameCount - 1 { continue }
            // torch.stft centers the 400-sample window in a 512-sample FFT,
            // and zero-pads the waveform by 256. Only frames 0..<200 are kept.
            for j in 0..<400 {
                let source = frame * 160 + j - 200
                inputReal[j + 56] = (audio.indices.contains(source) ? audio[source] : 0) * hann[j]
            }
            // Complex-to-complex FFT avoids the factor-of-two convention and
            // packed DC/Nyquist bins of vDSP's real FFT. No FFT normalization.
            vDSP_DFT_Execute(setup, inputReal, inputImaginary, &outputReal, &outputImaginary)
            for bin in 0..<257 {
                power[bin] = outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin]
            }
            vDSP_mmul(filters, 1, power, 1, &melFrame, 1, 128, 1, 257)
            for mel in 0..<Self.melCount {
                cachedMels[mel * Self.frameCount + (cacheStart + frame) % Self.frameCount] = logf(max(melFrame[mel], 1e-10))
            }
        }
        cachedMels.withUnsafeBufferPointer { cached in
            for mel in 0..<Self.melCount {
                let row = output.advanced(by: mel * melStride)
                let source = cached.baseAddress!.advanced(by: mel * Self.frameCount)
                if frameStride == 1 {
                    row.update(from: source + cacheStart, count: Self.frameCount - cacheStart)
                    (row + Self.frameCount - cacheStart).update(from: source, count: cacheStart)
                } else {
                    for frame in 0..<Self.frameCount {
                        row[frame * frameStride] = source[(cacheStart + frame) % Self.frameCount]
                    }
                }
                // Avoid reduction roundoff creating a nonzero silent feature.
                if (1..<Self.frameCount).allSatisfy({ row[$0 * frameStride] == row[0] }) {
                    for frame in 0..<Self.frameCount { row[frame * frameStride] = 0 }
                    continue
                }
                var mean: Float = 0
                vDSP_meanv(row, vDSP_Stride(frameStride), &mean, 200)
                var negativeMean = -mean
                vDSP_vsadd(row, vDSP_Stride(frameStride), &negativeMean, row, vDSP_Stride(frameStride), 200)
                var variance: Float = 0
                vDSP_measqv(row, vDSP_Stride(frameStride), &variance, 200)
                var inverseStd = 1 / (sqrtf(max(variance, 0)) + 1e-5)
                vDSP_vsmul(row, vDSP_Stride(frameStride), &inverseStd, row, vDSP_Stride(frameStride), 200)
            }
        }
    }

    private static func makeSlaneyFilters() -> [Float] {
        let logStep = log(6.4) / 27
        let maxMel = 15 + log(8.0) / logStep
        let hz = (0..<130).map { index -> Double in
            let mel = Double(index) * maxMel / 129
            return mel < 15 ? mel * (200.0 / 3) : 1000 * exp((mel - 15) * logStep)
        }
        var result = [Float](repeating: 0, count: 128 * 257)
        for mel in 0..<128 {
            for bin in 0..<257 {
                let frequency = Double(bin) * 8000 / 256
                let lower = (frequency - hz[mel]) / (hz[mel + 1] - hz[mel])
                let upper = (hz[mel + 2] - frequency) / (hz[mel + 2] - hz[mel + 1])
                result[mel * 257 + bin] = Float(max(0, min(lower, upper)) * 2 / (hz[mel + 2] - hz[mel]))
            }
        }
        return result
    }
}
