import Foundation
import NativServerKit

struct MLXImageModelResolver: Sendable {
    static let shared = MLXImageModelResolver(
        supportedModelTypes: (try? Nativ.imageGenerationModelTypes())
            ?? ["bonsai", "flux2", "ideogram4"]
    )

    private let supportedModelTypes: Set<String>

    init(supportedModelTypes: Set<String>) {
        self.supportedModelTypes = supportedModelTypes
    }

    func isImageGenerationModel(
        model: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        var candidates = localModelTypes(at: root, fileManager: fileManager)
        addModelType(modelType(from: model), to: &candidates)

        for candidate in candidates where supportedModelTypes.contains(candidate) {
            if supportsLocalLayout(
                modelType: candidate,
                at: root,
                fileManager: fileManager
            ) {
                return true
            }
        }
        return false
    }

    private func localModelTypes(
        at root: URL,
        fileManager: FileManager
    ) -> [String] {
        var candidates: [String] = []

        for filename in ["model_index.json", "config.json"] {
            let url = root.appendingPathComponent(filename)
            if let metadata = loadJSONObject(at: url, fileManager: fileManager) {
                addMetadataCandidates(metadata, to: &candidates)
            }
        }

        let manifestURL = root.appendingPathComponent("manifest.json")
        if let manifest = loadJSONObject(at: manifestURL, fileManager: fileManager),
            isBonsaiManifest(manifest)
        {
            addModelType("bonsai", to: &candidates)
        }

        let componentURLs =
            (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        for componentURL in componentURLs.sorted(by: { $0.path < $1.path }) {
            let configURL = componentURL.appendingPathComponent("config.json")
            if let metadata = loadJSONObject(
                at: configURL,
                fileManager: fileManager
            ) {
                addMetadataCandidates(metadata, to: &candidates)
            }
        }

        return candidates
    }

    private func addMetadataCandidates(
        _ metadata: [String: Any],
        to candidates: inout [String]
    ) {
        addModelType(metadata["model_type"], to: &candidates)
        addClassNameCandidates(metadata["_class_name"], to: &candidates)

        for component in ["transformer", "vae", "scheduler", "text_encoder"] {
            let value = metadata[component]
            if let values = value as? [Any], let className = values.last {
                addClassNameCandidates(className, to: &candidates)
            } else if let value = value as? [String: Any] {
                addClassNameCandidates(
                    value["_class_name"] ?? value["class"],
                    to: &candidates
                )
            }
        }
    }

    private func addClassNameCandidates(
        _ value: Any?,
        to candidates: inout [String]
    ) {
        guard let value else {
            return
        }
        let className = String(describing: value)
        let range = NSRange(className.startIndex..., in: className)
        let tokens = Self.pascalCaseTokenRegex.matches(
            in: className,
            range: range
        ).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: className) else {
                return nil
            }
            return String(className[tokenRange])
        }

        if !tokens.isEmpty {
            for end in 1 ... tokens.count {
                addModelType(
                    tokens.prefix(end).joined(separator: "_"),
                    to: &candidates
                )
            }
        }
        for token in tokens {
            addModelType(token, to: &candidates)
        }
    }

    private func addModelType(_ value: Any?, to candidates: inout [String]) {
        guard let normalized = normalizedModelType(value),
            !candidates.contains(normalized)
        else {
            return
        }
        candidates.append(normalized)
    }

    private func normalizedModelType(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = String(describing: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard !normalized.isEmpty,
            normalized.range(
                of: #"^[a-z_][a-z0-9_]*$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        return normalized
    }

    private func modelType(from model: String) -> String? {
        let normalized =
            model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let name = normalized.split(separator: "/").last else {
            return nil
        }
        let modelType = String(name.split(separator: "-", maxSplits: 1).first ?? name)
        switch modelType {
        case "ternary", "2bit":
            return "bonsai"
        case "flux.2", "flux2", "klein":
            return "flux2"
        default:
            return normalizedModelType(modelType)
        }
    }

    private func isBonsaiManifest(_ manifest: [String: Any]) -> Bool {
        guard let entries = manifest["files"] as? [Any] else {
            return false
        }
        let paths = Set(
            entries.compactMap { entry -> String? in
                if let path = entry as? String {
                    return path
                }
                guard let entry = entry as? [String: Any] else {
                    return nil
                }
                return [
                    "remote_path",
                    "path",
                    "filename",
                    "name",
                ].compactMap { entry[$0] as? String }.first
            })
        return paths.contains(
            "transformer-packed-mflux/diffusion_pytorch_model.safetensors"
        )
            && paths.contains("text_encoder-mlx-4bit/model.safetensors")
            && paths.contains("tokenizer/tokenizer.json")
    }

    private func loadJSONObject(
        at url: URL,
        fileManager: FileManager
    ) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func supportsLocalLayout(
        modelType: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        switch modelType {
        case "bonsai":
            return [
                "transformer-packed-mflux/diffusion_pytorch_model.safetensors",
                "text_encoder-mlx-4bit/model.safetensors",
                "tokenizer/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(
                    atPath: root.appendingPathComponent($0).path
                )
            }
        case "flux2":
            return hasSafetensors(
                in: "transformer",
                at: root,
                fileManager: fileManager
            )
                && hasSafetensors(
                    in: "text_encoder",
                    at: root,
                    fileManager: fileManager
                )
                && hasSafetensors(in: "vae", at: root, fileManager: fileManager)
                && fileManager.fileExists(
                    atPath: root.appendingPathComponent(
                        "tokenizer/tokenizer.json"
                    ).path
                )
        case "ideogram4":
            let componentDirectories = [
                "transformer",
                "unconditional_transformer",
                "text_encoder",
                "vae",
            ]
            return componentDirectories.allSatisfy {
                hasSafetensors(in: $0, at: root, fileManager: fileManager)
                    && fileManager.fileExists(
                        atPath: root.appendingPathComponent(
                            "\($0)/config.json"
                        ).path
                    )
            }
                && fileManager.fileExists(
                    atPath: root.appendingPathComponent(
                        "tokenizer/tokenizer.json"
                    ).path
                )
        default:
            // The generated manifest is authoritative for newly bundled
            // backends whose local layout is not yet known to the app.
            return true
        }
    }

    private func hasSafetensors(
        in directory: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        let directoryURL = root.appendingPathComponent(directory)
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return contents.contains { $0.pathExtension == "safetensors" }
    }

    private static let pascalCaseTokenRegex = try! NSRegularExpression(
        pattern: #"[A-Z][a-z0-9]*|[A-Z]+(?=[A-Z]|$)"#
    )
}
