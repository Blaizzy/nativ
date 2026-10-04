import Foundation
import NativServerKit

/// A prefilled GitHub issue asking the runtime maintainers to support a Hub
/// model whose type the bundled runtime cannot load. Only models classified
/// unsupported, with a task Nativ runs and safetensors weights, qualify.
///
/// Requests are keyed by `model_type`, since one port covers every checkpoint
/// of that type. The title prefix is the key used to find an existing request.
struct ModelSupportRequest: Equatable, Sendable {
    let repoID: String
    let modelType: String
    let architectures: [String]
    let pipelineTag: String
    let runtimeVersions: [String: String]
    let appVersion: String

    static let bundledRuntimeVersions: [String: String] =
        (try? Nativ.modelTypeRegistry().packageVersions) ?? [:]

    /// Hub tasks Nativ has a surface for. Unsupported models outside these
    /// (detection, forecasting, segmentation, robotics, …) would have nowhere
    /// to run even after a port, so they are not offered a request.
    private static let requestablePipelineTags: Set<String> = [
        "text-generation",
        "image-text-to-text",
        "image-to-text",
        "visual-question-answering",
        "video-text-to-text",
        "audio-text-to-text",
        "any-to-any",
        "automatic-speech-recognition",
        "text-to-speech",
        "text-to-audio",
        "feature-extraction",
        "sentence-similarity",
        "text-ranking",
        "text-to-image",
        "image-to-image",
    ]

    private static let audioPipelineTags: Set<String> = [
        "automatic-speech-recognition",
        "text-to-speech",
        "text-to-audio",
    ]

    init?(
        model: HuggingFaceModel,
        runtimeVersions: [String: String] = Self.bundledRuntimeVersions,
        appVersion: String = ReleaseVersion.displayString(in: Bundle.main.infoDictionary)
    ) {
        guard model.support == .unsupported,
              !model.isPrivate,
              let configuration = model.supportConfiguration,
              let pipelineTag = model.pipelineTag?.lowercased(),
              Self.requestablePipelineTags.contains(pipelineTag),
              model.tags.contains(where: { $0.lowercased() == "safetensors" }),
              let modelType = configuration.modelType?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !modelType.isEmpty
        else {
            return nil
        }
        self.repoID = model.id
        self.modelType = modelType
        self.architectures = configuration.architectures
        self.pipelineTag = pipelineTag
        self.runtimeVersions = runtimeVersions
        self.appVersion = appVersion
    }

    var repository: String {
        Self.audioPipelineTags.contains(pipelineTag)
            ? "Blaizzy/mlx-audio"
            : "Blaizzy/mlx-vlm"
    }

    var runtimeName: String {
        repository.components(separatedBy: "/").last ?? repository
    }

    var titlePrefix: String {
        "[Model request] \(modelType):"
    }

    var title: String {
        "\(titlePrefix) \(repoID)"
    }

    var body: String {
        let versions = runtimeVersions.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
        var sections = [
            "### Model\n[\(repoID)](https://huggingface.co/\(repoID))",
            "### Model type\n`\(modelType)`",
        ]
        if !architectures.isEmpty {
            sections.append(
                "### Architectures\n" + architectures.map { "`\($0)`" }.joined(separator: ", ")
            )
        }
        sections.append("### Task\n`\(pipelineTag)`")
        sections.append(
            "### What would you use it for?\n_Optional: your use case, the modalities you need, anything that helps prioritize._"
        )
        var environment = ["- Nativ \(appVersion)"]
        if !versions.isEmpty {
            environment.append("- \(versions)")
        }
        sections.append("### Environment\n" + environment.joined(separator: "\n"))
        sections.append("<sub>Requested from the Nativ Models page.</sub>")
        return sections.joined(separator: "\n\n")
    }

    var newIssueURL: URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components?.url
    }

    var existingIssueSearchURL: URL? {
        var components = URLComponents(string: "https://api.github.com/search/issues")
        components?.queryItems = [
            URLQueryItem(
                name: "q",
                value: "repo:\(repository) is:issue is:open in:title \"Model request\" \"\(modelType)\""
            ),
            URLQueryItem(name: "per_page", value: "20"),
        ]
        return components?.url
    }

    /// The first open request whose title carries this model type's prefix.
    func matchingIssueURL(inSearchResponse data: Data) -> URL? {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return nil
        }
        let prefix = titlePrefix.lowercased()
        return response.items.first {
            $0.title.lowercased().hasPrefix(prefix)
        }?.htmlURL
    }

    /// Resolves to an existing open request when one is found, otherwise to a
    /// new prefilled issue. Lookup failures fall back to the new issue.
    func issueURL(session: URLSession = .shared) async -> URL? {
        if let searchURL = existingIssueSearchURL {
            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 5
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MLXPlatform/1.0", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let existing = matchingIssueURL(inSearchResponse: data)
            {
                return existing
            }
        }
        return newIssueURL
    }

    private struct SearchResponse: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let title: String
            let htmlURL: URL

            enum CodingKeys: String, CodingKey {
                case title
                case htmlURL = "html_url"
            }
        }
    }
}

enum InstalledModelSupportVerdict: Equatable, Sendable {
    /// Loadable, undetermined, or not a Hub model.
    case unconfirmed
    case unsupported(ModelSupportRequest?)
}

/// Vets installed models the same way Discover vets Hub results. The local
/// config.json is screened with the bundled classifier first, so only models
/// it would reject cost a Hub lookup for the task and tags it can't see
/// locally. Verdicts are cached per snapshot; failed lookups are retried.
actor InstalledModelSupportResolver {
    static let shared = InstalledModelSupportResolver()

    private let client = HuggingFaceHubClient()
    private var verdicts: [String: InstalledModelSupportVerdict] = [:]

    func verdict(for localModel: LocalModel, token: String?) async -> InstalledModelSupportVerdict {
        guard localModel.source == .huggingFaceCache, let snapshotURL = localModel.snapshotURL else {
            return .unconfirmed
        }
        let key = snapshotURL.standardizedFileURL.path
        if let verdict = verdicts[key] {
            return verdict
        }
        guard Self.localConfigurationMayBeUnsupported(snapshotURL: snapshotURL) else {
            verdicts[key] = .unconfirmed
            return .unconfirmed
        }
        guard let data = try? await client.modelData(id: localModel.repoID, token: token),
              let hubModel = try? JSONDecoder().decode(HuggingFaceModel.self, from: data)
        else {
            return .unconfirmed
        }
        let verdict: InstalledModelSupportVerdict = hubModel.support == .unsupported
            ? .unsupported(ModelSupportRequest(model: hubModel))
            : .unconfirmed
        verdicts[key] = verdict
        return verdict
    }

    /// The Hub-only inputs are filled with a task the classifier accepts, so
    /// this rejects exactly the configs the Hub lookup could confirm.
    static func localConfigurationMayBeUnsupported(snapshotURL: URL) -> Bool {
        guard let data = try? Data(
                  contentsOf: snapshotURL.appendingPathComponent("config.json")
              ),
              let configuration = try? JSONDecoder().decode(
                  HuggingFaceModelSupportConfiguration.self,
                  from: data
              )
        else {
            return false
        }
        return HuggingFaceModelSupportClassifier.bundled?.classify(
            configuration: configuration,
            pipelineTag: "text-generation",
            tags: []
        ) == .unsupported
    }
}
