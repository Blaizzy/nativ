import NativServerKit
import XCTest

final class HuggingFaceModelSupportTests: XCTestCase {
    func testCanonicalAndAliasModelTypesAreSupported() throws {
        let classifier = try makeClassifier()

        for modelType in ["language-loader", "language-alias", "LANGUAGE-LOADER"] {
            let result = classifier.classify(
                configuration: try configuration(modelType: modelType),
                pipelineTag: "text-generation",
                tags: []
            )

            XCTAssertEqual(result, .supported, modelType)
        }
    }

    func testSpeculatorModelTypeCanEstablishSupport() throws {
        let result = try makeClassifier().classify(
            configuration: configuration([
                "model_type": "unrecognized-wrapper",
                "speculators_model_type": "drafter-loader",
            ]),
            pipelineTag: "text-generation",
            tags: ["draft-model"]
        )

        XCTAssertEqual(result, .supported)
    }

    func testUnknownStandardModelWithExplicitTaskIsUnsupported() throws {
        let result = try makeClassifier().classify(
            configuration: configuration([
                "model_type": "not-in-the-bundled-runtime",
                "architectures": ["UnsupportedForCausalLM"],
            ]),
            pipelineTag: "text-generation",
            tags: []
        )

        XCTAssertEqual(result, .unsupported)
    }

    func testMissingEvidenceRemainsUnknown() throws {
        let classifier = try makeClassifier()

        XCTAssertEqual(
            classifier.classify(
                configuration: nil,
                pipelineTag: "text-generation",
                tags: []
            ),
            .unknown
        )
        XCTAssertEqual(
            classifier.classify(
                configuration: try configuration(modelType: "unrecognized"),
                pipelineTag: nil,
                tags: []
            ),
            .unknown
        )
        XCTAssertEqual(
            classifier.classify(
                configuration: try configuration([:]),
                pipelineTag: "text-generation",
                tags: []
            ),
            .unknown
        )
    }

    func testCustomCodeEvidencePreventsUnsupportedClassification() throws {
        let classifier = try makeClassifier()
        let configurations: [[String: Any]] = [
            [
                "model_type": "unrecognized",
                "model_file": "model.py",
            ],
            [
                "model_type": "unrecognized",
                "auto_map": ["AutoModel": "model.CustomModel"],
            ],
        ]

        for payload in configurations {
            XCTAssertEqual(
                classifier.classify(
                    configuration: try configuration(payload),
                    pipelineTag: "text-generation",
                    tags: []
                ),
                .unknown
            )
        }

        for tag in ["custom_code", "trust_remote_code", "CUSTOM_CODE"] {
            XCTAssertEqual(
                classifier.classify(
                    configuration: try configuration(modelType: "unrecognized"),
                    pipelineTag: "text-generation",
                    tags: [tag]
                ),
                .unknown,
                tag
            )
        }
    }

    func testAmbiguousModalityAndDFlashMetadataRemainUnknown() throws {
        let classifier = try makeClassifier()
        let configurations: [[String: Any]] = [
            [
                "model_type": "unrecognized",
                "vision_config": ["hidden_size": 1_024],
            ],
            [
                "model_type": "unrecognized",
                "audio_config": ["hidden_size": 1_024],
            ],
            [
                "model_type": "unrecognized",
                "dflash_config": ["num_layers": 1],
            ],
        ]

        for payload in configurations {
            XCTAssertEqual(
                classifier.classify(
                    configuration: try configuration(payload),
                    pipelineTag: "text-generation",
                    tags: []
                ),
                .unknown
            )
        }
    }

    func testExplicitSpecialLoaderArchitecturesAreSupported() throws {
        let classifier = try makeClassifier()

        for architecture in ["BoundaryExtractor", "DFlash2DraftModel"] {
            let result = classifier.classify(
                configuration: try configuration([
                    "architectures": [architecture]
                ]),
                pipelineTag: nil,
                tags: []
            )

            XCTAssertEqual(result, .supported, architecture)
        }
    }

    func testConfigurationDecoderDistinguishesPresentMetadataFromNullValues() throws {
        let populated = try configuration([
            "model_type": "language-loader",
            "architectures": ["ExampleForCausalLM"],
            "vision_config": ["hidden_size": 1_024],
            "audio_config": ["hidden_size": 768],
            "dflash_config": ["num_layers": 1],
            "auto_map": ["AutoModel": "model.CustomModel"],
        ])

        XCTAssertEqual(populated.modelType, "language-loader")
        XCTAssertEqual(populated.architectures, ["ExampleForCausalLM"])
        XCTAssertTrue(populated.hasVisionConfig)
        XCTAssertTrue(populated.hasAudioConfig)
        XCTAssertTrue(populated.hasDFlashConfig)
        XCTAssertTrue(populated.usesCustomCode)

        let nullMetadata = try configuration([
            "model_type": "language-loader",
            "vision_config": NSNull(),
            "audio_config": NSNull(),
            "dflash_config": NSNull(),
            "auto_map": NSNull(),
        ])

        XCTAssertFalse(nullMetadata.hasVisionConfig)
        XCTAssertFalse(nullMetadata.hasAudioConfig)
        XCTAssertFalse(nullMetadata.hasDFlashConfig)
        XCTAssertFalse(nullMetadata.usesCustomCode)
    }

    func testMalformedOptionalMetadataDoesNotRejectHubModel() throws {
        let payload: [String: Any] = [
            "id": "test/malformed-config-model",
            "pipeline_tag": "text-generation",
            "config": [
                "model_type": 42,
                "architectures": "UnexpectedArchitecture",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let model = try JSONDecoder().decode(HuggingFaceModel.self, from: data)

        XCTAssertEqual(model.support, .unknown)
    }

    func testHubConfigurationImprovesProviderDetection() throws {
        let payload: [String: Any] = [
            "id": "community/generic-model",
            "pipeline_tag": "text-generation",
            "config": [
                "model_type": "qwen3",
                "architectures": ["Qwen3ForCausalLM"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let model = try JSONDecoder().decode(HuggingFaceModel.self, from: data)

        XCTAssertEqual(model.supportConfiguration?.modelType, "qwen3")
        XCTAssertEqual(model.provider, .qwen)
    }

    private func configuration(
        modelType: String
    ) throws -> HuggingFaceModelSupportConfiguration {
        try configuration(["model_type": modelType])
    }

    private func configuration(
        _ payload: [String: Any]
    ) throws -> HuggingFaceModelSupportConfiguration {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(HuggingFaceModelSupportConfiguration.self, from: data)
    }

    private func makeClassifier() throws -> HuggingFaceModelSupportClassifier {
        var capabilities: [String: Any] = [:]
        for capability in NativModelCapability.allCases {
            capabilities[capability.rawValue] = [
                "model_types": ["test_\(capability.rawValue)"],
                "aliases": [:],
            ]
        }
        capabilities[NativModelCapability.language.rawValue] = [
            "model_types": ["language-loader"],
            "aliases": ["language-alias": "language-loader"],
        ]
        capabilities[NativModelCapability.speculativeDrafters.rawValue] = [
            "model_types": ["drafter-loader"],
            "aliases": [:],
            "kinds": ["drafter-loader": "mtp"],
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "package_versions": ["mlx-vlm": "test", "mlx-audio": "test"],
            "capabilities": capabilities,
        ])
        let registry = try NativModelTypeRegistry(data: data)
        return HuggingFaceModelSupportClassifier(registry: registry)
    }
}
