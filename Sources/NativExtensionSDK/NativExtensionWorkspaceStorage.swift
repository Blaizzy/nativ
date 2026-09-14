import Foundation

/// The host supplies the directory; package-controlled keys never become paths.
public struct NativExtensionWorkspaceStorage: Sendable {
    public static let maximumBytes = 1_048_576
    private let fileURL: URL
    private let fields: [String: NativWorkspaceField]

    public init(directory: URL, fields: [String: NativWorkspaceField]) {
        self.fileURL = directory.appendingPathComponent("workspace.json")
        self.fields = fields
    }

    public func load() throws -> [String: NativWorkflowValue] {
        var values = fields.mapValues(\.defaultValue)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return values }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw NativDashboardError.invalid("Saved workspace exceeds its size limit.")
        }
        let saved = try JSONDecoder().decode([String: NativWorkflowValue].self, from: data)
        for (key, value) in saved where fields[key]?.type.accepts(value) == true {
            values[key] = value
        }
        return values
    }

    public func save(_ values: [String: NativWorkflowValue]) throws {
        guard Set(values.keys) == Set(fields.keys),
              values.allSatisfy({ fields[$0.key]?.type.accepts($0.value) == true }) else {
            throw NativDashboardError.invalid("Stored values must match their declared fields.")
        }
        let data = try JSONEncoder().encode(values)
        guard data.count <= Self.maximumBytes else {
            throw NativDashboardError.invalid("Workspace exceeds its size limit.")
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
