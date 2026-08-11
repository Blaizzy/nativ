import NativServerKit
import XCTest

final class MLXAudioModelResolverTests: XCTestCase {
    private let resolver = MLXAudioModelResolver(
        backendCapabilities: NativAudioModelCapabilities(
            speechToTextModelTypes: ["backend_transcriber"],
            textToSpeechModelTypes: ["backend_synthesizer"]
        )
    )

    func testUsesBackendManifestModelTypes() {
        XCTAssertEqual(
            resolver.capabilities(
                config: ["model_type": "backend_transcriber"],
                modelIndex: [:]
            ),
            [.audio, .speechToText]
        )
        XCTAssertEqual(
            resolver.capabilities(
                config: ["model_type": "backend-synthesizer"],
                modelIndex: [:]
            ),
            [.audio, .textToSpeech]
        )
    }

    func testRecognizesGenericTaskMetadataWithoutModelNames() {
        let capabilities = resolver.capabilities(
            config: [
                "target": "vendor.audio.asr.models.Recognizer",
                "encoder": ["_target_": "vendor.audio.encoders.GenericEncoder"],
            ],
            modelIndex: [:]
        )

        XCTAssertEqual(capabilities, [.audio, .speechToText])
    }

    func testRecognizesStandardPipelineTags() {
        XCTAssertEqual(
            resolver.capabilities(
                config: [:],
                modelIndex: ["pipeline_tag": "automatic-speech-recognition"]
            ),
            [.audio, .speechToText]
        )
        XCTAssertEqual(
            resolver.capabilities(
                config: [:],
                modelIndex: ["pipeline_tag": "text-to-speech"]
            ),
            [.audio, .textToSpeech]
        )
    }

    func testDoesNotInferCapabilitiesFromUnrelatedMetadata() {
        XCTAssertTrue(
            resolver.capabilities(
                config: ["model_type": "unknown", "sample_rate": 16_000],
                modelIndex: [:]
            ).isEmpty
        )
    }
}
