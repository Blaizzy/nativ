import XCTest

final class CodexCLIProfileTests: XCTestCase {
    private var temporaryHome: URL!

    override func setUpWithError() throws {
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativCodexCLIProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryHome {
            try FileManager.default.removeItem(at: temporaryHome)
        }
        temporaryHome = nil
    }

    func testWritingCLIProfileLeavesBaseCodexConfigurationUnchanged() throws {
        let codexDirectory = temporaryHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let baseConfigurationURL = codexDirectory.appendingPathComponent("config.toml")
        let profileConfigurationURL = CodexCLIProfile.configurationURL(in: temporaryHome)
        let baseConfiguration = "model_provider = \"openai\"\n[features]\nfast_mode = true\n"
        try Data(baseConfiguration.utf8).write(to: baseConfigurationURL)

        try CodexCLIProfile.write(selectedModelID: "org/local-model", homeDirectory: temporaryHome)

        XCTAssertEqual(profileConfigurationURL, codexDirectory.appendingPathComponent("nativ.config.toml"))
        XCTAssertEqual(try String(contentsOf: baseConfigurationURL, encoding: .utf8), baseConfiguration)
        XCTAssertEqual(
            try String(contentsOf: profileConfigurationURL, encoding: .utf8),
            CodexCLIProfile.contents(selectedModelID: "org/local-model")
        )
    }

    func testReconfiguringReplacesTheCLIProfileWithoutAccumulatingManagedBlocks() throws {
        try CodexCLIProfile.write(selectedModelID: "first-model", homeDirectory: temporaryHome)
        try CodexCLIProfile.write(selectedModelID: "second-model", homeDirectory: temporaryHome)

        let configuration = try String(
            contentsOf: CodexCLIProfile.configurationURL(in: temporaryHome),
            encoding: .utf8
        )
        XCTAssertEqual(configuration, CodexCLIProfile.contents(selectedModelID: "second-model"))
        XCTAssertFalse(configuration.contains("first-model"))
        XCTAssertEqual(configuration.components(separatedBy: "# Managed by Nativ.").count - 1, 1)
    }
}
