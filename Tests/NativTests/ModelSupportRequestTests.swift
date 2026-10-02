import XCTest

final class ModelSupportRequestTests: XCTestCase {
    func testTextModelRequestTargetsMLXVLMWithPrefilledIssue() throws {
        let request = try XCTUnwrap(
            makeRequest(
                id: "deepseek-ai/DeepSeek-V4.1-Flash",
                pipelineTag: "text-generation",
                config: [
                    "model_type": "deepseek_v41",
                    "architectures": ["DeepseekV41ForCausalLM"],
                ]
            )
        )

        XCTAssertEqual(request.repository, "Blaizzy/mlx-vlm")
        XCTAssertEqual(request.runtimeName, "mlx-vlm")
        XCTAssertEqual(
            request.title,
            "[Model request] deepseek_v41: deepseek-ai/DeepSeek-V4.1-Flash"
        )
        XCTAssertTrue(request.body.contains("### Model type\n`deepseek_v41`"))
        XCTAssertTrue(request.body.contains("`DeepseekV41ForCausalLM`"))
        XCTAssertTrue(request.body.contains("- Nativ 1.2.3"))
        XCTAssertTrue(request.body.contains("- mlx-audio 0.5.5 · mlx-vlm 0.7.1"))

        let url = try XCTUnwrap(request.newIssueURL)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/Blaizzy/mlx-vlm/issues/new")
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "title" }?.value,
            request.title
        )
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "body" }?.value,
            request.body
        )
    }

    func testSpeechModelRequestTargetsMLXAudio() throws {
        let request = try XCTUnwrap(
            makeRequest(
                id: "moondream/parakeet-redux",
                pipelineTag: "automatic-speech-recognition",
                config: ["model_type": "parakeet_tdt"]
            )
        )

        XCTAssertEqual(request.repository, "Blaizzy/mlx-audio")
    }

    func testOnlyModelsClassifiedUnsupportedCanBeRequested() throws {
        XCTAssertNil(
            try makeRequest(
                id: "Qwen/Qwen3-8B",
                pipelineTag: "text-generation",
                config: ["model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"]]
            )
        )
        XCTAssertNil(
            try makeRequest(
                id: "test/custom-code",
                pipelineTag: "text-generation",
                config: ["model_type": "brand_new", "auto_map": ["AutoConfig": "x.Y"]]
            )
        )
        XCTAssertNil(
            try makeRequest(
                id: "test/speculator",
                pipelineTag: "text-generation",
                config: ["model_type": " ", "speculators_model_type": "eagle9"]
            )
        )
    }

    func testPrivateOrUntypedModelsCannotBeRequested() throws {
        XCTAssertNil(
            try makeRequest(
                id: "me/private-model",
                pipelineTag: "text-generation",
                config: ["model_type": "secret_arch"],
                isPrivate: true
            )
        )
        XCTAssertNil(
            try makeRequest(id: "test/untyped", pipelineTag: "text-generation", config: [:])
        )
    }

    func testExistingRequestMatchesOnlyTheSameModelTypePrefix() throws {
        let request = try XCTUnwrap(
            makeRequest(
                id: "other/DeepSeek-V4.1-Pro",
                pipelineTag: "text-generation",
                config: ["model_type": "deepseek_v41"]
            )
        )
        let response: [String: Any] = [
            "items": [
                [
                    "title": "[Model request] deepseek_v41_mtp: other/draft",
                    "html_url": "https://github.com/Blaizzy/mlx-vlm/issues/1",
                ],
                [
                    "title": "DeepSeek-V4.1 decode is slow",
                    "html_url": "https://github.com/Blaizzy/mlx-vlm/issues/2",
                ],
                [
                    "title": "[Model Request] DEEPSEEK_V41: deepseek-ai/DeepSeek-V4.1-Flash",
                    "html_url": "https://github.com/Blaizzy/mlx-vlm/issues/3",
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        XCTAssertEqual(
            request.matchingIssueURL(inSearchResponse: data)?.absoluteString,
            "https://github.com/Blaizzy/mlx-vlm/issues/3"
        )
        XCTAssertNil(request.matchingIssueURL(inSearchResponse: Data("{}".utf8)))
    }

    func testModelsWithNowhereToRunInNativCannotBeRequested() throws {
        XCTAssertNil(
            try makeRequest(
                id: "PekingU/rtdetr_v2_r50vd",
                pipelineTag: "object-detection",
                config: ["model_type": "rt_detr_v2"]
            )
        )
        XCTAssertNil(
            try makeRequest(
                id: "amazon/chronos-2",
                pipelineTag: "time-series-forecasting",
                config: ["model_type": "t5"]
            )
        )
        XCTAssertNil(
            try makeRequest(
                id: "rzgar/Bernini-v2-ComfyUI",
                pipelineTag: "image-text-to-video",
                config: ["model_type": "bernini"]
            )
        )
    }

    func testModelsWithoutSafetensorsWeightsCannotBeRequested() throws {
        XCTAssertNil(
            try makeRequest(
                id: "onnx-community/Kokoro-82M-v1.0-ONNX",
                pipelineTag: "text-to-speech",
                config: ["model_type": "style_text_to_speech_2"],
                tags: ["onnx", "transformers.js"]
            )
        )
    }

    func testInstalledConfigScreenOnlyPassesConfigsTheClassifierWouldReject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func snapshot(_ config: [String: Any]?) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let config {
                try JSONSerialization.data(withJSONObject: config)
                    .write(to: url.appendingPathComponent("config.json"))
            }
            return url
        }

        XCTAssertTrue(
            InstalledModelSupportResolver.localConfigurationMayBeUnsupported(
                snapshotURL: try snapshot(["model_type": "unported_arch"])
            )
        )
        XCTAssertFalse(
            InstalledModelSupportResolver.localConfigurationMayBeUnsupported(
                snapshotURL: try snapshot(["model_type": "qwen3"])
            )
        )
        XCTAssertFalse(
            InstalledModelSupportResolver.localConfigurationMayBeUnsupported(
                snapshotURL: try snapshot([
                    "model_type": "unported_arch",
                    "auto_map": ["AutoConfig": "x.Y"],
                ])
            )
        )
        XCTAssertFalse(
            InstalledModelSupportResolver.localConfigurationMayBeUnsupported(
                snapshotURL: try snapshot(nil)
            )
        )
    }

    private func makeRequest(
        id: String,
        pipelineTag: String,
        config: [String: Any],
        tags: [String] = ["transformers", "safetensors"],
        isPrivate: Bool = false
    ) throws -> ModelSupportRequest? {
        let payload: [String: Any] = [
            "id": id,
            "pipeline_tag": pipelineTag,
            "tags": tags,
            "private": isPrivate,
            "config": config,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let model = try JSONDecoder().decode(HuggingFaceModel.self, from: data)
        return ModelSupportRequest(
            model: model,
            runtimeVersions: ["mlx-vlm": "0.7.1", "mlx-audio": "0.5.5"],
            appVersion: "1.2.3"
        )
    }
}
