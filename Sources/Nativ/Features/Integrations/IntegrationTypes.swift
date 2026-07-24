import Foundation

enum IntegrationTool: String, CaseIterable, Hashable, Identifiable, Sendable {
    case pi
    case codex
    case claudeCode
    case hermes
    case openCode
    case aider
    case goose
    case crush
    case qwenCode
    case openClaw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .hermes: "Hermes"
        case .openCode: "OpenCode"
        case .aider: "Aider"
        case .goose: "Goose"
        case .crush: "Crush"
        case .qwenCode: "Qwen Code"
        case .openClaw: "OpenClaw"
        }
    }

    var commandName: String {
        switch self {
        case .pi: "pi"
        case .codex: "codex"
        case .claudeCode: "claude"
        case .hermes: "hermes"
        case .openCode: "opencode"
        case .aider: "aider"
        case .goose: "goose"
        case .crush: "crush"
        case .qwenCode: "qwen"
        case .openClaw: "openclaw"
        }
    }

    var logoAssetName: String { "IntegrationLogo-\(rawValue)" }

    var summary: String {
        switch self {
        case .pi: "Minimal, extensible coding agent"
        case .codex: "OpenAI coding agent for the terminal"
        case .claudeCode: "Anthropic's agentic coding tool"
        case .hermes: "Open agent with tools, skills, and memory"
        case .openCode: "Open-source coding agent"
        case .aider: "AI pair programming in your terminal"
        case .goose: "Extensible on-machine AI agent"
        case .crush: "Glamourous terminal coding agent"
        case .qwenCode: "Agentic coding CLI tuned for Qwen"
        case .openClaw: "Open personal AI agent and gateway"
        }
    }

    var installURL: URL {
        switch self {
        case .pi: URL(string: "https://pi.dev/docs/latest")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/setup")!
        case .hermes: URL(string: "https://github.com/NousResearch/hermes-agent")!
        case .openCode: URL(string: "https://opencode.ai/docs")!
        case .aider: URL(string: "https://aider.chat/docs/install.html")!
        case .goose: URL(string: "https://github.com/block/goose")!
        case .crush: URL(string: "https://github.com/charmbracelet/crush")!
        case .qwenCode: URL(string: "https://github.com/QwenLM/qwen-code")!
        case .openClaw: URL(string: "https://docs.openclaw.ai/")!
        }
    }

    var preferredModelHint: String? {
        switch self {
        case .qwenCode: "Tuned for Qwen models — works with any model served here."
        default: nil
        }
    }
}

struct IntegrationModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let contextWindow: Int?
    let supportsVision: Bool
    let supportsReasoning: Bool
    let supportsTools: Bool
}

struct IntegrationToolStatus: Equatable, Sendable {
    var executableURL: URL?
    var version: String?
    var isConfigured: Bool

    static let unavailable = IntegrationToolStatus(executableURL: nil, version: nil, isConfigured: false)
}

enum IntegrationServiceError: LocalizedError {
    case missingExecutable(IntegrationTool)
    case invalidConfiguration(URL)
    case noModel
    case serverUnavailable
    case modelLoadFailed(String, String)
    case modelLoadTimedOut(String)
    case terminalLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let tool):
            return "\(tool.displayName) is not installed or could not be found in the application bundle or shell PATH."
        case .invalidConfiguration(let url):
            return "The existing configuration at \(url.path) is not valid JSON. It was left unchanged."
        case .noModel:
            return "Choose an installed chat model first."
        case .serverUnavailable:
            return "The local model server did not become ready in time."
        case .modelLoadFailed(let model, let message):
            return "Couldn’t load \(model): \(message)"
        case .modelLoadTimedOut(let model):
            return "Loading \(model) took longer than five minutes. The coding tool was not opened."
        case .terminalLaunchFailed(let message):
            return "Couldn’t open Terminal: \(message)"
        }
    }
}
