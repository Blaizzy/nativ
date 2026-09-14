import Foundation

/// A value flowing between workflow steps.
///
/// Typed rather than JSON-shaped so a later slice can carry images and audio
/// between steps without restringifying them. `data` is deliberately not
/// encodable: an authored input can only ever be a literal, while a binary
/// value can only ever be produced by a step at run time.
public enum NativWorkflowValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case data(Data, uti: String)
    case list([NativWorkflowValue])
    case object([String: NativWorkflowValue])
    case none

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

extension NativWorkflowValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([NativWorkflowValue].self) {
            self = .list(value)
        } else if let value = try? container.decode([String: NativWorkflowValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported workflow value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .none: try container.encodeNil()
        case .data:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: container.codingPath, debugDescription: "Binary values are produced at run time and cannot be written to a workflow")
            )
        }
    }
}

extension NativWorkflowValue {
    var references: [NativWorkflowReference] {
        switch self {
        case .text(let value):
            NativWorkflowReference.references(in: value)
        case .list(let values):
            values.flatMap(\.references)
        case .object(let values):
            values.values.flatMap(\.references)
        case .number, .boolean, .data, .none:
            []
        }
    }
}

/// The outputs of one step, addressed by later steps as `{{step.output}}`.
public typealias NativWorkflowStepOutput = [String: NativWorkflowValue]

/// A `{{step.output}}` binding inside a step input.
public struct NativWorkflowReference: Hashable, Sendable {
    public let step: String
    public let output: String?

    public init(step: String, output: String?) {
        self.step = step
        self.output = output
    }

    public init?(_ raw: String) {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        self.step = parts[0]
        self.output = parts.count == 2 ? parts[1] : nil
    }

    static func hasMalformedReferences(in text: String) -> Bool {
        guard let pattern else { return true }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text),
                  NativWorkflowReference(String(text[range])) != nil else { return true }
        }
        let literal = pattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..<text.endIndex, in: text), withTemplate: ""
        )
        return literal.contains("{{") || literal.contains("}}")
    }

    private static let pattern = try? NSRegularExpression(
        pattern: "\\{\\{([A-Za-z0-9_.-]+)\\}\\}"
    )

    /// Every binding in the order it appears.
    public static func references(in text: String) -> [NativWorkflowReference] {
        guard let pattern else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return NativWorkflowReference(String(text[captured]))
        }
    }
}

/// Operations a declarative package may compose. Closed by design: the safety
/// property of a package that carries no code is that only these can happen.
public enum NativWorkflowOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case readSelection = "text.readSelection"
    case readClipboard = "text.readClipboard"
    case insertText = "text.insert"
    case replaceSelection = "text.replaceSelection"
    case invokeModel = "model.invoke"
    case recordAudio = "audio.record"
    case transcribeAudio = "audio.transcribe"
    case captureScreen = "screen.capture"
    case saveFile = "file.save"
    case writeClipboard = "clipboard.write"
    case showOverlay = "overlay.show"
    case showNotification = "notification.show"
    case readStorage = "storage.read"
    case writeStorage = "storage.write"

    /// `nil` for `invokeModel`, whose permission comes from its task.
    /// Mirror of `OPERATION_PERMISSIONS` in the marketplace's scripts/validate.py.
    public var requiredPermission: NativExtensionPermission? {
        switch self {
        case .readSelection: .readSelection
        case .readClipboard: .readClipboard
        case .insertText, .replaceSelection: .accessibilityInsertText
        case .invokeModel: nil
        case .recordAudio: .microphone
        case .transcribeAudio: .modelsSpeechToText
        case .captureScreen: .screenCapture
        case .saveFile: .saveFile
        case .writeClipboard: .writeClipboard
        case .showOverlay: .overlay
        case .showNotification: .notifications
        case .readStorage, .writeStorage: .namespacedStorage
        }
    }
}

public enum NativWorkflowModelTask: String, Codable, CaseIterable, Hashable, Sendable {
    case language
    case vision
    case imageGeneration
    case imageEditing
    case speechToText
    case textToSpeech
    case embedding

    public var requiredPermission: NativExtensionPermission {
        switch self {
        case .language: .modelsLanguage
        case .vision: .modelsVision
        case .imageGeneration: .modelsImageGeneration
        case .imageEditing: .modelsImageEditing
        case .speechToText: .modelsSpeechToText
        case .textToSpeech: .modelsTextToSpeech
        case .embedding: .modelsEmbedding
        }
    }
}

public struct NativWorkflowTrigger: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case shortcut
        case command
    }

    public let id: String
    public let type: Kind
    public let shortcut: String?
    public let commandID: String?
    public let steps: [String]?

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["id", "type", "shortcut", "commandID", "steps"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(Kind.self, forKey: .type)
        shortcut = try container.decodeIfPresent(String.self, forKey: .shortcut)
        commandID = try container.decodeIfPresent(String.self, forKey: .commandID)
        steps = try container.decodeIfPresent([String].self, forKey: .steps)
    }

    public init(id: String, type: Kind, shortcut: String? = nil, commandID: String? = nil, steps: [String]? = nil) {
        self.id = id
        self.type = type
        self.shortcut = shortcut
        self.commandID = commandID
        self.steps = steps
    }
}

/// One step. `type` and `task` stay as written so an unrecognised value becomes
/// a validation error naming it, rather than a decode failure that discards the
/// whole document.
public struct NativWorkflowStep: Codable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let task: String?
    public let model: String?
    public let inputs: [String: NativWorkflowValue]
    public let maxTokens: Int?
    public let temperature: Double?

    public var operation: NativWorkflowOperation? { .init(rawValue: type) }
    public var modelTask: NativWorkflowModelTask? { task.flatMap(NativWorkflowModelTask.init) }

    public init(
        id: String,
        type: String,
        task: String? = nil,
        model: String? = nil,
        inputs: [String: NativWorkflowValue] = [:],
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.task = task
        self.model = model
        self.inputs = inputs
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["id", "type", "task", "model", "inputs", "maxTokens", "temperature"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        task = try container.decodeIfPresent(String.self, forKey: .task)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        inputs = try container.decodeIfPresent(
            [String: NativWorkflowValue].self,
            forKey: .inputs
        ) ?? [:]
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
    }
}

public struct NativExtensionWorkflow: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let triggers: [NativWorkflowTrigger]
    public let steps: [NativWorkflowStep]

    public init(
        schemaVersion: Int = NativExtensionWorkflow.currentSchemaVersion,
        triggers: [NativWorkflowTrigger],
        steps: [NativWorkflowStep]
    ) {
        self.schemaVersion = schemaVersion
        self.triggers = triggers
        self.steps = steps
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownExtensionFields(decoder, allowed: ["schemaVersion", "triggers", "steps"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        triggers = try container.decode([NativWorkflowTrigger].self, forKey: .triggers)
        steps = try container.decode([NativWorkflowStep].self, forKey: .steps)
    }

    public func steps(forCommand commandID: String) -> [NativWorkflowStep] {
        guard let trigger = trigger(forCommand: commandID) else { return [] }
        guard let ids = trigger.steps else { return steps }
        return ids.compactMap { id in steps.first(where: { $0.id == id }) }
    }

    public func trigger(forCommand commandID: String) -> NativWorkflowTrigger? {
        triggers.first { $0.type == .command && $0.commandID == commandID }
    }
}

private struct WorkflowField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func rejectUnknownExtensionFields(_ decoder: any Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: WorkflowField.self)
    if let unknown = container.allKeys.sorted(by: { $0.stringValue < $1.stringValue })
        .first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath + [unknown],
            debugDescription: "Unknown field “\(unknown.stringValue)”."
        ))
    }
}
