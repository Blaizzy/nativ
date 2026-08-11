import Foundation
import NativServerKit

struct MLXAudioModelResolver: Sendable {
    static let shared = MLXAudioModelResolver(
        backendCapabilities: (try? Nativ.audioModelCapabilities())
            ?? NativAudioModelCapabilities(
                speechToTextModelTypes: [],
                textToSpeechModelTypes: []
            )
    )

    private static let modelTypeKeys: Set<String> = ["model_type", "architecture"]
    private static let taskDescriptorKeys: Set<String> = [
        "_class_name",
        "_target_",
        "architectures",
        "pipeline_tag",
        "task",
        "target",
    ]

    private let speechToTextModelTypes: Set<String>
    private let textToSpeechModelTypes: Set<String>

    init(backendCapabilities: NativAudioModelCapabilities) {
        speechToTextModelTypes = Set(
            backendCapabilities.speechToTextModelTypes.map(Self.normalizedModelType)
        )
        textToSpeechModelTypes = Set(
            backendCapabilities.textToSpeechModelTypes.map(Self.normalizedModelType)
        )
    }

    func capabilities(
        config: [String: Any],
        modelIndex: [String: Any]
    ) -> Set<LocalModelCapability> {
        let metadata = [config, modelIndex]
        let modelTypes = Set(
            metadata
                .flatMap { Self.stringValues(forKeys: Self.modelTypeKeys, in: $0) }
                .map(Self.normalizedModelType)
        )
        let descriptors = metadata.flatMap {
            Self.stringValues(forKeys: Self.taskDescriptorKeys, in: $0)
        }

        var result = Set<LocalModelCapability>()
        if !modelTypes.isDisjoint(with: speechToTextModelTypes)
            || descriptors.contains(where: Self.describesSpeechToText) {
            result.insert(.speechToText)
        }
        if !modelTypes.isDisjoint(with: textToSpeechModelTypes)
            || descriptors.contains(where: Self.describesTextToSpeech) {
            result.insert(.textToSpeech)
        }
        if !result.isEmpty {
            result.insert(.audio)
        }
        return result
    }

    private static func stringValues(forKeys keys: Set<String>, in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, value in
                var result: [String] = []
                if keys.contains(key) {
                    result.append(contentsOf: strings(in: value))
                }
                result.append(contentsOf: stringValues(forKeys: keys, in: value))
                return result
            }
        }
        if let array = value as? [Any] {
            return array.flatMap { stringValues(forKeys: keys, in: $0) }
        }
        return []
    }

    private static func strings(in value: Any) -> [String] {
        if let value = value as? String {
            return [value]
        }
        if let array = value as? [Any] {
            return array.flatMap(strings)
        }
        return []
    }

    private static func describesSpeechToText(_ value: String) -> Bool {
        let descriptor = value.lowercased()
        let tokens = semanticTokens(in: descriptor)
        return tokens.contains("asr")
            || descriptor.contains("automatic-speech-recognition")
            || descriptor.contains("speechrecognition")
            || descriptor.contains("transcrib")
    }

    private static func describesTextToSpeech(_ value: String) -> Bool {
        let descriptor = value.lowercased()
        let tokens = semanticTokens(in: descriptor)
        return tokens.contains("tts")
            || descriptor.contains("text-to-speech")
            || descriptor.contains("texttospeech")
            || descriptor.contains("speechsynthesis")
    }

    private static func semanticTokens(in value: String) -> Set<String> {
        Set(
            value.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
    }

    private static func normalizedModelType(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}
