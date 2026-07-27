import AppKit

enum LocalModelProvider: String, Hashable, Sendable {
    case google
    case openAI
    case meta
    case mistral
    case qwen
    case microsoft
    case cohere
    case deepSeek
    case ai2
    case openBMB
    case openMOSS
    case poolside
    case prismML
    case blackForestLabs
    case nvidia
    case apple
    case ibm
    case liquidAI
    case zAI

    var displayName: String {
        switch self {
        case .google: "Google"
        case .openAI: "OpenAI"
        case .meta: "Meta"
        case .mistral: "Mistral AI"
        case .qwen: "Qwen"
        case .microsoft: "Microsoft"
        case .cohere: "Cohere"
        case .deepSeek: "DeepSeek"
        case .ai2: "Ai2"
        case .openBMB: "OpenBMB"
        case .openMOSS: "OpenMOSS"
        case .poolside: "Poolside"
        case .prismML: "Prism ML"
        case .blackForestLabs: "Black Forest Labs"
        case .nvidia: "NVIDIA"
        case .apple: "Apple"
        case .ibm: "IBM"
        case .liquidAI: "Liquid AI"
        case .zAI: "Z.ai"
        }
    }

    var iconResourceName: String? {
        switch self {
        case .google: "ModelProviderIcon-google"
        case .openAI: "ModelProviderIcon-openai"
        case .meta: "ModelProviderIcon-meta"
        case .mistral: "ModelProviderIcon-mistral"
        case .qwen: "ModelProviderIcon-qwen"
        case .microsoft: "ModelProviderIcon-microsoft"
        case .cohere: "ModelProviderIcon-cohere"
        case .deepSeek: "ModelProviderIcon-deepseek"
        case .ai2: "ModelProviderIcon-ai2"
        case .openBMB: "ModelProviderIcon-openbmb"
        case .openMOSS: "ModelProviderIcon-openmoss"
        case .poolside: "ModelProviderIcon-poolside"
        case .prismML: "ModelProviderIcon-prism-ml"
        case .blackForestLabs: "ModelProviderIcon-bfl"
        case .nvidia: "ModelProviderIcon-nvidia"
        case .apple: "ModelProviderIcon-apple"
        case .ibm: "ModelProviderIcon-ibm"
        case .liquidAI: "ModelProviderIcon-liquid"
        case .zAI: "ModelProviderIcon-zai"
        }
    }

    var monogram: String {
        switch self {
        case .google: "G"
        case .openAI: "AI"
        case .meta: "M"
        case .mistral: "M"
        case .qwen: "Q"
        case .microsoft: "MS"
        case .cohere: "C"
        case .deepSeek: "D"
        case .ai2: "A2"
        case .openBMB: "B"
        case .openMOSS: "M"
        case .poolside: "P"
        case .prismML: "P"
        case .blackForestLabs: "BFL"
        case .nvidia: "N"
        case .apple: "A"
        case .ibm: "IBM"
        case .liquidAI: "L"
        case .zAI: "Z"
        }
    }

    var preservesIconColors: Bool {
        switch self {
        case .google, .mistral, .microsoft, .cohere, .openBMB, .openMOSS, .poolside, .prismML:
            true
        default:
            false
        }
    }

    var needsLightIconBackgroundInDarkMode: Bool {
        self == .prismML
    }

    var iconTintColor: NSColor {
        switch self {
        case .google, .openAI, .mistral, .microsoft, .cohere, .apple, .liquidAI, .zAI:
            .labelColor
        case .meta:
            NSColor(srgbRed: 0 / 255, green: 129 / 255, blue: 251 / 255, alpha: 1)
        case .qwen:
            NSColor(srgbRed: 0 / 255, green: 46 / 255, blue: 254 / 255, alpha: 1)
        case .deepSeek:
            NSColor(srgbRed: 79 / 255, green: 112 / 255, blue: 255 / 255, alpha: 1)
        case .ai2:
            NSColor(srgbRed: 255 / 255, green: 103 / 255, blue: 170 / 255, alpha: 1)
        case .openBMB, .openMOSS, .poolside, .prismML:
            .labelColor
        case .blackForestLabs:
            .labelColor
        case .nvidia:
            NSColor(srgbRed: 118 / 255, green: 185 / 255, blue: 0 / 255, alpha: 1)
        case .ibm:
            NSColor(srgbRed: 15 / 255, green: 98 / 255, blue: 254 / 255, alpha: 1)
        }
    }
}

enum LocalModelProviderResolver {
    private struct ModelFamilyMapping {
        let provider: LocalModelProvider
        let identifiers: [String]
    }

    // Recognized first-party organizations are authoritative. Family mappings handle
    // converted and quantized models republished by mlx-community or another account.
    private static let modelFamilyMappings: [ModelFamilyMapping] = [
        ModelFamilyMapping(
            provider: .google,
            identifiers: ["gemma", "paligemma", "shieldgemma", "recurrentgemma", "diffusiongemma"]
        ),
        ModelFamilyMapping(provider: .qwen, identifiers: ["qwen"]),
        ModelFamilyMapping(
            provider: .mistral,
            identifiers: ["mistral", "mixtral", "devstral", "ministral", "pixtral"]
        ),
        ModelFamilyMapping(provider: .microsoft, identifiers: ["phi"]),
        ModelFamilyMapping(provider: .cohere, identifiers: ["cohere", "command", "aya"]),
        ModelFamilyMapping(provider: .ai2, identifiers: ["olmo", "molmo"]),
        ModelFamilyMapping(provider: .openBMB, identifiers: ["minicpm"]),
        ModelFamilyMapping(provider: .openMOSS, identifiers: ["moss"]),
        ModelFamilyMapping(provider: .poolside, identifiers: ["laguna"]),
        ModelFamilyMapping(provider: .prismML, identifiers: ["bonsai"]),
        ModelFamilyMapping(provider: .blackForestLabs, identifiers: ["flux"]),
        ModelFamilyMapping(provider: .openAI, identifiers: ["gptoss", "whisper"]),
        ModelFamilyMapping(provider: .meta, identifiers: ["llama"]),
        ModelFamilyMapping(provider: .deepSeek, identifiers: ["deepseek"]),
        ModelFamilyMapping(provider: .nvidia, identifiers: ["nemotron"]),
        ModelFamilyMapping(provider: .apple, identifiers: ["openelm"]),
        ModelFamilyMapping(provider: .ibm, identifiers: ["granite"]),
        ModelFamilyMapping(provider: .liquidAI, identifiers: ["lfm"]),
        ModelFamilyMapping(provider: .zAI, identifiers: ["glm", "cogvlm", "cogvideo"])
    ]

    private static let organizationMappings: [String: LocalModelProvider] = [
        "google": .google,
        "googledeepmind": .google,
        "openai": .openAI,
        "meta": .meta,
        "metallama": .meta,
        "facebook": .meta,
        "mistralai": .mistral,
        "qwen": .qwen,
        "alibaba": .qwen,
        "alibabacloud": .qwen,
        "microsoft": .microsoft,
        "cohere": .cohere,
        "coherelabs": .cohere,
        "cohereforai": .cohere,
        "deepseekai": .deepSeek,
        "allenai": .ai2,
        "ai2": .ai2,
        "openbmb": .openBMB,
        "openmoss": .openMOSS,
        "openmossteam": .openMOSS,
        "poolside": .poolside,
        "poolsideai": .poolside,
        "prismml": .prismML,
        "blackforestlabs": .blackForestLabs,
        "nvidia": .nvidia,
        "apple": .apple,
        "ibm": .ibm,
        "ibmgranite": .ibm,
        "liquidai": .liquidAI,
        "liquid": .liquidAI,
        "zai": .zAI,
        "zaiorg": .zAI,
        "zhipuai": .zAI,
        "thudm": .zAI
    ]

    static func resolve(
        repoID: String,
        modelType: String?,
        architectures: [String]
    ) -> LocalModelProvider? {
        if let organization = repoID.split(separator: "/").first,
           let provider = organizationMappings[normalizedKey(String(organization))] {
            return provider
        }

        let repositoryName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let modelDescriptors = [modelType ?? ""] + architectures + [repositoryName]
        let candidates = modelDescriptors.flatMap(normalizedCandidates)

        for mapping in modelFamilyMappings
            where mapping.identifiers.contains(where: { identifier in
                candidates.contains(where: { $0.hasPrefix(identifier) })
            }) {
            return mapping.provider
        }
        return nil
    }

    private static func normalizedCandidates(_ value: String) -> [String] {
        let lowercase = value.lowercased()
        let segments = lowercase
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let collapsed = normalizedKey(lowercase)
        return collapsed.isEmpty ? segments : segments + [collapsed]
    }

    private static func normalizedKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

@MainActor
enum LocalModelProviderIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [LocalModelProvider: NSImage] = [:]

    static func image(for provider: LocalModelProvider) -> NSImage? {
        if let cached = cache[provider] {
            return cached
        }
        guard let resourceName = provider.iconResourceName else {
            return nil
        }

        let bundle = Bundle.main
        let resourceURL = bundle.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "ModelProviderIcons"
        ) ?? bundle.url(forResource: resourceName, withExtension: "svg")

        guard let resourceURL,
              let image = NSImage(contentsOf: resourceURL) else {
            return nil
        }

        image.size = size
        image.isTemplate = !provider.preservesIconColors
        cache[provider] = image
        return image
    }
}
