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
    case zed
    case continueDev
    case vscode
    case cline
    case cursor
    case jetbrains

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
        case .zed: "Zed"
        case .continueDev: "Continue"
        case .vscode: "VS Code"
        case .cline: "Cline"
        case .cursor: "Cursor"
        case .jetbrains: "JetBrains"
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
        case .zed: "zed"
        case .continueDev: "cn"
        case .vscode: "code"
        case .cline: "cline"
        case .cursor: "cursor"
        case .jetbrains: "jetbrains"
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
        case .zed: "High-performance, multiplayer code editor"
        case .continueDev: "Open-source AI code assistant"
        case .vscode: "Copilot BYOK via an OpenAI-compatible endpoint"
        case .cline: "OpenAI-compatible provider in the Cline extension"
        case .cursor: "OpenAI-compatible endpoint in Cursor's AI panel"
        case .jetbrains: "OpenAI-compatible endpoint in JetBrains AI Assistant"
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
        case .zed: URL(string: "https://zed.dev/download")!
        case .continueDev: URL(string: "https://docs.continue.dev/cli/quickstart")!
        case .vscode: URL(string: "https://code.visualstudio.com/docs/copilot/language-models")!
        case .cline: URL(string: "https://marketplace.visualstudio.com/items?itemName=saoudrizwan.claude-dev")!
        case .cursor: URL(string: "https://docs.cursor.com/settings/models")!
        case .jetbrains: URL(string: "https://www.jetbrains.com/help/ai-assistant/configure-openai-compatible-models.html")!
        }
    }

    var preferredModelHint: String? {
        switch self {
        case .qwenCode: "Tuned for Qwen models — works with any model served here."
        default: nil
        }
    }

    var isGuidedSetup: Bool {
        switch self {
        case .vscode: true
        case .cline: true
        case .cursor: true
        case .jetbrains: true
        default: false
        }
    }

    var appBundleIdentifier: String? {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        default: nil
        }
    }

    var guidedSetupSteps: [String] {
        switch self {
        case .vscode:
            [
                "Start Nativ's server and load a model from the Models page.",
                "In VS Code, open the Command Palette and run \u{201C}Chat: Manage Language Models\u{201D}.",
                "Choose \u{201C}OpenAI Compatible\u{201D}, set the Base URL and API key shown above, then pick your model.",
                "Or install a community \u{201C}OpenAI Compatible\u{201D} chat extension and point it at the same Base URL and key."
            ]
        case .cline:
            [
                "Start Nativ's server and load a model from the Models page.",
                "Install the Cline extension in VS Code (or a compatible editor).",
                "Open Cline's settings and add an API Provider of type \u{201C}OpenAI Compatible\u{201D}.",
                "Set the Base URL and API key shown above, then select your model."
            ]
        case .cursor:
            [
                "Start Nativ's server and load a model from the Models page.",
                "In Cursor, open Settings \u{2192} Models.",
                "Enable \u{201C}Override OpenAI Base URL\u{201D} and set the Base URL and API key shown above.",
                "Add your model name, then select it in the chat model picker."
            ]
        case .jetbrains:
            [
                "Start Nativ's server and load a model from the Models page.",
                "In your JetBrains IDE, open Settings \u{2192} Tools \u{2192} AI Assistant \u{2192} Models.",
                "Under Providers & API keys, add an \u{201C}OpenAI Compatible\u{201D} provider with the Base URL and API key shown above.",
                "Select your model, then use it from the AI Assistant chat."
            ]
        default:
            []
        }
    }

    var guidedSetupCaveat: String? {
        switch self {
        case .vscode: "Copilot BYOK requires the GitHub Copilot extension, signed in."
        case .cline: "Cline runs inside VS Code and compatible editors."
        case .cursor: "Only Cursor's chat/AI panel honors a custom OpenAI endpoint \u{2014} Tab and inline edits stay on Cursor's own models."
        case .jetbrains: "Requires the AI Assistant plugin (recent JetBrains IDE versions)."
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
