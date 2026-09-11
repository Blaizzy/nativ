import Foundation

/// The public release version is independent of Sparkle's increasing build number.
struct ReleaseVersion: Comparable, Sendable {
    let components: [Int]
    let candidate: Int?

    init?(_ value: String) {
        guard value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?(rc[1-9][0-9]*)?$"#,
            options: .regularExpression
        ) == value.startIndex..<value.endIndex else { return nil }
        let parts = value.components(separatedBy: "rc")
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == parts[0].split(separator: ".").count else { return nil }
        components = numbers.count == 2 ? numbers + [0] : numbers
        if parts.count == 2 {
            guard let number = Int(parts[1]) else { return nil }
            candidate = number
        } else {
            candidate = nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.components != rhs.components {
            return lhs.components.lexicographicallyPrecedes(rhs.components)
        }
        switch (lhs.candidate, rhs.candidate) {
        case let (.some(left), .some(right)): return left < right
        case (.some, .none): return true
        default: return false
        }
    }

    static func displayString(in info: [String: Any]?) -> String {
        if let release = info?["NativReleaseVersion"] as? String,
           ReleaseVersion(release) != nil {
            return release
        }
        return info?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

enum SoftwareUpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case releaseCandidates

    static let storageKey = "softwareUpdateChannel"
    var id: Self { self }
    var title: String { self == .stable ? "Stable" : "Release Candidates" }
    var allowedChannels: Set<String> { self == .stable ? [] : ["rc"] }

    /// Fail closed if either the release version or channel metadata is malformed.
    func permits(version: String, channel: String?, installedVersion: String) -> Bool {
        guard let release = ReleaseVersion(version),
              let installed = ReleaseVersion(installedVersion),
              release >= installed else { return false }
        if release.candidate != nil {
            return self == .releaseCandidates && channel == "rc"
        }
        return channel == nil
    }
}
