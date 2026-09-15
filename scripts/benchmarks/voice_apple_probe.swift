// Replay a WAV through the same SpeechTranscriber configuration as the wake listener.
// Deliberately uses files rather than a microphone, so no ambient audio is collected.
import AVFoundation
import Foundation
import Speech

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

@MainActor
@main
struct AppleVoiceProbe {
    static func main() async {
        do {
            let path = CommandLine.arguments[1]
            let realtime = CommandLine.arguments.dropFirst(2).first != "fast"
            let startup = ProcessInfo.processInfo.systemUptime
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            else { throw NSError(domain: "No English recognizer", code: 1) }
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            _ = try await AssetInventory.reserve(locale: locale)
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw NSError(domain: "English model is not installed; benchmark does not download models", code: 2)
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            else { throw NSError(domain: "No audio format", code: 3) }
            let analyzer = SpeechAnalyzer(modules: [module],
                options: .init(priority: .utility, modelRetention: .whileInUse))
            let context = AnalysisContext()
            context.contextualStrings[.general] = ["hey nativ", "hey native"]
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let duration = Double(file.length) / file.processingFormat.sampleRate
            emit(["event": "ready", "pid": ProcessInfo.processInfo.processIdentifier,
                  "startup_seconds": ProcessInfo.processInfo.systemUptime - startup,
                  "audio_seconds": duration, "sample_rate": format.sampleRate])
            guard readLine() == "go" else { await analyzer.cancelAndFinishNow(); return }
            let started = ProcessInfo.processInfo.systemUptime
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
            let bridge = VoiceWakeWordAudioBridge(format: format, continuation: continuation) {
                emit(["event": "error", "message": "audio conversion failed"])
            }
            let results = Task {
                for try await result in module.results {
                    emit(["event": "result", "seconds": ProcessInfo.processInfo.systemUptime - started,
                          "audio_start": result.range.start.seconds, "audio_end": result.range.end.seconds,
                          "final": result.isFinal, "text": String(result.text.characters)])
                }
            }
            let analysis = Task { try await analyzer.analyzeSequence(stream) }
            let chunkSize = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
            var frames: AVAudioFramePosition = 0
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize)!
                try file.read(into: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                if realtime {
                    let target = started + Double(frames) / file.processingFormat.sampleRate
                    let delay = target - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                }
                bridge.append(buffer)
            }
            continuation.finish()
            _ = try await analysis.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
            emit(["event": "done", "elapsed_seconds": ProcessInfo.processInfo.systemUptime - started])
            // Keep the process alive for the external sampler's last snapshot.
            _ = readLine()
        } catch {
            emit(["event": "error", "message": String(describing: error)])
        }
    }
}
