import Accelerate
import AVFoundation
import Foundation

struct ParakeetMel: Sendable {
    let values: [Float]
    let validFrames: Int
    var totalFrames: Int { validFrames + 1 }
}

struct ParakeetAudio {
    static let sampleRate = 16000
    static let hop = 160
    static let melBins = 128
    static let fftSize = 512

    static let window: [Float] = (0..<fftSize).map { index in
        let n = index - 56
        return (0..<400).contains(n) ? Float(0.5 * (1 - cos(2 * Double.pi * Double(n) / 399))) : 0
    }

    static let filters: [[Float]] = {
        func mel(_ hz: Double) -> Double {
            hz < 1000 ? hz / (200.0 / 3) : 15 + log(hz / 1000) / (log(6.4) / 27)
        }
        func hz(_ mel: Double) -> Double {
            mel < 15 ? mel * (200.0 / 3) : 1000 * exp((mel - 15) * (log(6.4) / 27))
        }
        let vertices = (0..<130).map { hz(Double($0) * mel(8000) / 129) }
        return (0..<melBins).map { band in
            let left = vertices[band], center = vertices[band + 1], right = vertices[band + 2]
            return (0...256).map { bin in
                let frequency = Double(bin) * 16000 / 512
                let triangle = max(0, min((frequency - left) / (center - left), (right - frequency) / (right - center)))
                return Float(triangle * 2 / (right - left))
            }
        }
    }()

    static func preprocess(_ samples: [Float]) throws -> ParakeetMel {
        let valid = samples.count / hop
        guard valid >= 2 else { throw ParakeetError.tooShort }
        guard samples.allSatisfy(\.isFinite) else { throw ParakeetError.invalidAudio }
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else {
            throw ParakeetError.invalidAudio
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var emphasized = samples
        for n in 1..<samples.count { emphasized[n] = samples[n] - 0.97 * samples[n - 1] }
        var features = [Float](repeating: 0, count: (valid + 1) * melBins)
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = real
        var power = [Float](repeating: 0, count: 257)
        // The final centered frame is discarded after normalization, so leave it zero.
        for frame in 0..<valid {
            if frame.isMultiple(of: 64) { try Task.checkCancellation() }
            for n in 0..<fftSize {
                let index = frame * hop + n - 256
                real[n] = (emphasized.indices.contains(index) ? emphasized[index] : 0) * window[n]
                imaginary[n] = 0
            }
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            for bin in 0...256 { power[bin] = real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            for band in 0..<melBins {
                var melPower: Float = 0
                vDSP_dotpr(power, 1, filters[band], 1, &melPower, 257)
                features[frame * melBins + band] = log(melPower + 0x1p-24)
            }
        }
        for band in 0..<melBins {
            // Double accumulation avoids cancellation for near-constant/silent bands.
            let mean = (0..<valid).reduce(0.0) { $0 + Double(features[$1 * melBins + band]) } / Double(valid)
            let variance = (0..<valid).reduce(0.0) {
                let delta = Double(features[$1 * melBins + band]) - mean
                return $0 + delta * delta
            } / Double(valid - 1)
            let divisor = sqrt(variance) + 1e-5
            for frame in 0..<valid {
                let index = frame * melBins + band
                features[index] = Float((Double(features[index]) - mean) / divisor)
            }
        }
        guard features.allSatisfy(\.isFinite) else { throw ParakeetError.invalidAudio }
        return ParakeetMel(values: features, validFrames: valid)
    }

    /// Downmix by channel mean, then use AVAudioConverter's band-limited resampler.
    static func read(contentsOf url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount > 0, format.sampleRate > 0,
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096),
              let converter = AVAudioConverter(from: mono, to: target)
        else { throw ParakeetError.invalidAudio }
        var samples = [Float]()
        var readError: Error?
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                do {
                    let remaining = file.length - file.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity, AVAudioFrameCount(min(remaining, 4096))))
                    guard input.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    mixed.frameLength = input.frameLength
                    let channels = input.floatChannelData!
                    let destination = mixed.floatChannelData![0]
                    for frame in 0..<Int(input.frameLength) {
                        var sum: Float = 0
                        for channel in 0..<Int(format.channelCount) { sum += channels[channel][frame] }
                        destination[frame] = sum / Float(format.channelCount)
                    }
                    state.pointee = .haveData
                    return mixed
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw ParakeetError.invalidAudio }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { break }
            guard output.frameLength > 0 else { throw ParakeetError.invalidAudio }
        }
        return samples
    }
}
