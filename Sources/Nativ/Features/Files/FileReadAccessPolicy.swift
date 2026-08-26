import Darwin
import Foundation

enum FileReadAccessError: Error, Equatable, Sendable {
    case notConfigured
    case invalidPath
    case outsideAllowedRoot
    case blockedPath
    case specialPath
}

struct ResolvedFileReadPath: Equatable, Sendable {
    let url: URL
    let displayPath: String
}

struct FileReadAccessPolicy: Sendable {
    let rootURL: URL

    init(rootPath: String?) throws {
        guard let rootURL = Self.configuredRootURL(rootPath: rootPath) else {
            throw FileReadAccessError.notConfigured
        }
        self.rootURL = rootURL
    }

    static func isConfigured(rootPath: String?) -> Bool {
        configuredRootURL(rootPath: rootPath) != nil
    }

    static func configuredRootURL(rootPath: String?) -> URL? {
        guard let rootPath else { return nil }
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let root = canonicalURL(
            URL(fileURLWithPath: expanded, isDirectory: true)
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else {
            return nil
        }
        return root
    }

    func resolve(path: String) throws -> ResolvedFileReadPath {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw FileReadAccessError.invalidPath
        }

        let expandedPath: String
        if path == "~" || path.hasPrefix("~/") {
            expandedPath = NSString(string: path).expandingTildeInPath
        } else {
            expandedPath = path
        }

        let candidate: URL
        if expandedPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expandedPath)
        } else {
            candidate = rootURL.appendingPathComponent(expandedPath)
        }

        let standardizedCandidate = candidate.standardizedFileURL
        try Self.rejectBlockedPath(standardizedCandidate)

        let resolved = Self.canonicalURL(standardizedCandidate)
        guard contains(resolved) else {
            throw FileReadAccessError.outsideAllowedRoot
        }
        try Self.rejectBlockedPath(resolved)

        return ResolvedFileReadPath(
            url: resolved,
            displayPath: displayPath(for: resolved)
        )
    }

    func contains(_ url: URL) -> Bool {
        let rootComponents = rootURL.pathComponents
        let targetComponents = url.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, targetComponents).allSatisfy { lhs, rhs in
            lhs == rhs
        }
    }

    func displayPath(for url: URL) -> String {
        let rootComponents = rootURL.pathComponents
        let targetComponents = url.pathComponents
        guard targetComponents.count >= rootComponents.count,
              zip(rootComponents, targetComponents).allSatisfy({ $0 == $1 }) else {
            return url.lastPathComponent
        }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    func suggestions(for missingURL: URL, maximumCount: Int = 3) -> [String] {
        let parent = Self.canonicalURL(missingURL.deletingLastPathComponent())
        guard contains(parent), maximumCount > 0,
              (try? Self.rejectBlockedPath(parent)) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return []
        }

        let needle = missingURL.lastPathComponent
        let ranked = names.prefix(300).compactMap { name -> (String, Int)? in
            let candidate = Self.canonicalURL(parent.appendingPathComponent(name))
            guard contains(candidate), (try? Self.rejectBlockedPath(candidate)) != nil else {
                return nil
            }
            let score = Self.suggestionScore(name: name, needle: needle)
            return score == nil ? nil : (name, score!)
        }
        return ranked
            .sorted {
                $0.1 == $1.1
                    ? $0.0.localizedStandardCompare($1.0) == .orderedAscending
                    : $0.1 < $1.1
            }
            .prefix(maximumCount)
            .map { displayPath(for: parent.appendingPathComponent($0.0)) }
    }

    private static func rejectBlockedPath(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let lowercasePath = path.lowercased()
        if ["/dev", "/proc", "/sys"].contains(where: {
            lowercasePath == $0 || lowercasePath.hasPrefix($0 + "/")
        }) {
            throw FileReadAccessError.specialPath
        }

        let components = url.pathComponents.map { $0.lowercased() }
        let blockedComponents: Set<String> = [
            ".ssh", ".gnupg", ".aws", ".azure", ".docker", ".git",
            "keychains", "gcloud",
        ]
        if components.contains(where: blockedComponents.contains) {
            throw FileReadAccessError.blockedPath
        }
        if components.windows(ofCount: 2).contains(where: {
            Array($0) == [".kube", "config"]
        }) {
            throw FileReadAccessError.blockedPath
        }
        if lowercasePath.contains("/library/application support/nativ/")
            || lowercasePath.hasSuffix("/library/application support/nativ") {
            throw FileReadAccessError.blockedPath
        }

        let name = url.lastPathComponent.lowercased()
        let blockedNames: Set<String> = [
            ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".gitconfig",
            "credentials", "credentials.json", "application_default_credentials.json",
            "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "known_hosts",
            "token", "stored_tokens", "auth.json",
        ]
        if name == ".env" || name.hasPrefix(".env.") || blockedNames.contains(name) {
            throw FileReadAccessError.blockedPath
        }
        let blockedExtensions: Set<String> = ["key", "pem", "p12", "pfx", "jks"]
        if blockedExtensions.contains(url.pathExtension.lowercased()) {
            throw FileReadAccessError.blockedPath
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        var cursor = url.standardizedFileURL
        var unresolvedComponents: [String] = []

        while true {
            if let resolvedPath = resolvedPath(cursor.path) {
                return unresolvedComponents.reversed().reduce(
                    URL(fileURLWithPath: resolvedPath)
                ) { partial, component in
                    partial.appendingPathComponent(component)
                }
            }
            guard cursor.path != "/" else { return url.standardizedFileURL }
            unresolvedComponents.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let pointer = Darwin.realpath(path, nil) else { return nil }
        defer { Darwin.free(pointer) }
        return String(cString: pointer)
    }

    private static func suggestionScore(name: String, needle: String) -> Int? {
        let lhs = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let rhs = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if lhs == rhs { return 0 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 1 }
        let distance = boundedEditDistance(lhs, rhs, limit: 3)
        return distance <= 3 ? distance + 1 : nil
    }

    private static func boundedEditDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let value = min(substitution, insertion, deletion)
                current.append(value)
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }
        return previous.last ?? limit + 1
    }
}

private extension Array {
    func windows(ofCount count: Int) -> [ArraySlice<Element>] {
        guard count > 0, self.count >= count else { return [] }
        return indices.dropLast(count - 1).map { start in
            self[start..<index(start, offsetBy: count)]
        }
    }
}
