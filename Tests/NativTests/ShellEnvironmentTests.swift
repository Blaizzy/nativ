import XCTest

final class ShellEnvironmentTests: XCTestCase {
    // MARK: - parseEnvironment

    func testParseEnvironmentReadsEntriesAfterMarker() {
        let output = "prompt junk\n\0\(ShellEnvironment.marker)\0HF_HOME=/Volumes/models\0PATH=/usr/bin\0"
        XCTAssertEqual(
            ShellEnvironment.parseEnvironment(output, names: ["HF_HOME"]),
            ["HF_HOME": "/Volumes/models"]
        )
    }

    func testParseEnvironmentIgnoresJunkBeforeMarker() {
        // Junk containing "=" would parse as a bogus entry without the marker.
        let output = "export FOO=bar\n\0\(ShellEnvironment.marker)\0HF_HOME=/x\0"
        XCTAssertEqual(
            ShellEnvironment.parseEnvironment(output, names: ["FOO", "HF_HOME"]),
            ["HF_HOME": "/x"]
        )
    }

    func testParseEnvironmentWithoutMarkerParsesEverything() {
        let output = "HF_HOME=/x\0IGNORED=y\0"
        XCTAssertEqual(
            ShellEnvironment.parseEnvironment(output, names: ["HF_HOME"]),
            ["HF_HOME": "/x"]
        )
    }

    func testParseEnvironmentPreservesValuesContainingEqualsAndNewlines() {
        let output = "TOKEN=abc=def\nghi\0"
        XCTAssertEqual(
            ShellEnvironment.parseEnvironment(output, names: ["TOKEN"]),
            ["TOKEN": "abc=def\nghi"]
        )
    }

    func testParseEnvironmentSkipsSegmentsWithoutSeparator() {
        let output = "garbage\0HF_HOME=/x\0"
        XCTAssertEqual(
            ShellEnvironment.parseEnvironment(output, names: ["HF_HOME"]),
            ["HF_HOME": "/x"]
        )
    }

    func testParseEnvironmentEmptyOutput() {
        XCTAssertEqual(ShellEnvironment.parseEnvironment("", names: ["HF_HOME"]), [:])
    }

    // MARK: - environment(executable:)

    func testEnvironmentReadsProcessOutput() {
        let result = ShellEnvironment.environment(
            names: ["HOME", "NATIV_TEST_DEFINITELY_MISSING"],
            executablePath: "/usr/bin/env",
            arguments: ["-0"],
            timeout: 5
        )
        XCTAssertNotNil(result["HOME"])
        XCTAssertNil(result["NATIV_TEST_DEFINITELY_MISSING"])
    }

    func testEnvironmentReturnsEmptyOnTimeout() {
        let start = Date()
        let result = ShellEnvironment.environment(
            names: ["HF_HOME"],
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: 0.2
        )
        XCTAssertEqual(result, [:])
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testEnvironmentReturnsEmptyForMissingExecutable() {
        let result = ShellEnvironment.environment(
            names: ["HF_HOME"],
            executablePath: "/nonexistent/shell",
            arguments: [],
            timeout: 1
        )
        XCTAssertEqual(result, [:])
    }
}
