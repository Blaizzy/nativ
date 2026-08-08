import ArgumentParser

@main
struct Nativ: AsyncParsableCommand {
    static let version = "0.2.0"
    static let configuration = CommandConfiguration(
        commandName: "nativ",
        abstract: "Local AI from your terminal — chat, serve, and manage models on the Nativ / mlx-vlm server.",
        discussion: """
        Everything runs against a local, OpenAI-compatible server — no cloud.

        Quick start:
          nativ serve -d                      # start the bundled server
          nativ models use <model-id>         # pick a default model
          nativ "write a haiku about metal"   # a bare prompt runs `run`
          nativ chat                          # interactive session

        Config resolves flag → env (NATIV_*) → cli.json → default.
        Run `nativ agent` for a full reference aimed at coding agents.
        """,
        version: version,
        subcommands: [Run.self, Chat.self, Serve.self, Status.self, Stop.self,
                      Models.self, Embed.self, Image.self, Transcribe.self, Audio.self,
                      Config.self, Agent.self],
        defaultSubcommand: Run.self
    )
}

/// Shared connection options. Adding a command = a new file that pulls this in;
/// no changes anywhere else.
struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("base-url"),
            help: "Server base URL (default: NATIV_BASE_URL, cli.json, or http://127.0.0.1:8080).")
    var baseURL: String?

    @Option(name: .customLong("api-key"),
            help: "API key (default: NATIV_API_KEY or cli.json).")
    var apiKey: String?

    init() {}
}
