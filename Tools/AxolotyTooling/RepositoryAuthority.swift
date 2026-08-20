// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A repository-authority validation finding.
public struct AxolotyRepositoryAuthorityFinding: Codable, Equatable, Sendable {
    /// The stable validation rule identifier.
    public let rule: String
    /// The repository-relative path associated with the finding, when known.
    public let path: String?
    /// The actionable diagnostic.
    public let message: String

    /// Creates a validation finding.
    public init(rule: String, path: String? = nil, message: String) {
        self.rule = rule
        self.path = path
        self.message = message
    }
}

/// The machine-readable result of repository-authority validation.
public struct AxolotyRepositoryAuthorityReport: Codable, Equatable, Sendable {
    /// The report schema version.
    public let schemaVersion: Int
    /// The checked repository version, when it could be read.
    public let version: String?
    /// `passed` when no findings exist, otherwise `failed`.
    public let status: String
    /// All validation findings in stable rule/path order.
    public let findings: [AxolotyRepositoryAuthorityFinding]

    /// Creates a validation report.
    public init(
        schemaVersion: Int = 1,
        version: String?,
        status: String,
        findings: [AxolotyRepositoryAuthorityFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.status = status
        self.findings = findings
    }
}

/// Validates the repository's current-version and documentation authority rules.
public struct AxolotyRepositoryAuthorityValidator: Sendable {
    /// The invariant identifier that no exception may waive.
    public static let nonWaivableInvariant = "INV-001"

    private let root: URL
    private let now: Date

    /// Creates a validator rooted at a repository checkout.
    ///
    /// - Parameters:
    ///   - root: The checkout root to inspect.
    ///   - now: The clock used for expiry checks, injectable for deterministic tests.
    public init(root: URL, now: Date = Date()) {
        self.root = root.standardizedFileURL
        self.now = now
    }

    /// Validates the repository without changing any files.
    public func validate() -> AxolotyRepositoryAuthorityReport {
        var findings: [AxolotyRepositoryAuthorityFinding] = []
        let version = readVersion(findings: &findings)
        if let version {
            validateVersionClaims(version, findings: &findings)
        }
        validateDocuments(findings: &findings)
        validateAgents(findings: &findings)
        let invariants = validateArchitecture(findings: &findings)
        validateExceptions(invariants: invariants, findings: &findings)
        findings.sort {
            ($0.path ?? "", $0.rule, $0.message) < ($1.path ?? "", $1.rule, $1.message)
        }
        return AxolotyRepositoryAuthorityReport(
            version: version,
            status: findings.isEmpty ? "passed" : "failed",
            findings: findings
        )
    }

    private func readVersion(findings: inout [AxolotyRepositoryAuthorityFinding]) -> String? {
        let path = "VERSION"
        guard let text = read(path)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            findings.append(.init(rule: "version.present", path: path, message: "VERSION is missing or empty"))
            return nil
        }
        guard isSemver(text) else {
            findings.append(.init(rule: "version.semver", path: path, message: "VERSION must contain a release semantic version such as 0.5.1"))
            return nil
        }
        return text
    }

    private func validateVersionClaims(
        _ version: String,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let claims: [(String, String, Bool)] = [
            ("README.md", #"from: "([0-9]+\.[0-9]+\.[0-9]+)""#, false),
            ("Makefile", #"AXOLOTY_CONSUMER_VERSION \?= ([0-9]+\.[0-9]+\.[0-9]+)"#, false),
            ("Tests/Support/check-axoloty-semver-consumer.sh", #"version=.*:-([0-9]+\.[0-9]+\.[0-9]+)\}"#, false),
            ("Tools/AxolotyTooling/AxolotyCommandDispatcher.swift", #"private static let version = "([0-9]+\.[0-9]+\.[0-9]+)""#, false),
            ("Tools/AxolotyInspectorCore/InspectorArgumentParser.swift", #"public static let version = "([0-9]+\.[0-9]+\.[0-9]+)""#, false),
            ("Tools/AxolotyToolingTests/AxolotyCommandDispatcherTests.swift", #"axoloty-tool ([0-9]+\.[0-9]+\.[0-9]+)"#, true),
            ("Tools/AxolotyToolingTests/AxolotyServeParserTests.swift", #"(?:ax|axoloty-tool) ([0-9]+\.[0-9]+\.[0-9]+)"#, true),
            ("Tools/AxolotyInspectorCoreTests/InspectorArgumentParserTests.swift", #"version == "([0-9]+\.[0-9]+\.[0-9]+)""#, true),
            ("docs/API.md", #"^# Axoloty ([0-9]+\.[0-9]+\.[0-9]+) API documentation"#, false),
            ("docs/SUPPORT_MATRIX.md", #"^# Axoloty ([0-9]+\.[0-9]+\.[0-9]+) support matrix"#, false),
        ]
        for (path, pattern, allMatches) in claims {
            guard let content = read(path) else {
                findings.append(.init(rule: "version.claim.present", path: path, message: "current-version consumer is missing"))
                continue
            }
            let values = regexCaptures(pattern, in: content)
            if values.isEmpty {
                findings.append(.init(rule: "version.claim", path: path, message: "no current-version claim matched the authority rule"))
                continue
            }
            if allMatches && values.contains(where: { $0 != version }) {
                findings.append(.init(rule: "version.claim", path: path, message: "every current-version claim must equal VERSION " + version + "; found " + values.joined(separator: ", ")))
            } else if !allMatches && values[0] != version {
                findings.append(.init(rule: "version.claim", path: path, message: "current-version claim " + values[0] + " does not equal VERSION " + version))
            }
        }
    }

    private func validateDocuments(findings: inout [AxolotyRepositoryAuthorityFinding]) {
        let required = [
            "ARCHITECTURE.md", "CONTEXT.md", "docs/ROADMAP.md",
            "docs/SUPPORT_MATRIX.md", "docs/protocol/coaty-core-3.md",
            "docs/architecture-exceptions.yml",
        ]
        for path in required where !fileExists(path) {
            findings.append(.init(rule: "documents.required", path: path, message: "required authority document is missing"))
        }
        for path in markdownPaths() {
            guard let content = read(path) else { continue }
            for target in markdownTargets(in: content) {
                if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") || target.hasPrefix("#") {
                    continue
                }
                let withoutFragment = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
                guard !withoutFragment.isEmpty else { continue }
                let base = URL(fileURLWithPath: path, relativeTo: root).deletingLastPathComponent()
                let resolved = URL(fileURLWithPath: withoutFragment, relativeTo: base).standardizedFileURL
                guard resolved.path.hasPrefix(root.path) else {
                    findings.append(.init(rule: "links.scope", path: path, message: "link escapes the repository: " + target))
                    continue
                }
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    findings.append(.init(rule: "links.resolve", path: path, message: "link target does not exist: " + target))
                }
            }
        }
    }

    private func validateAgents(findings: inout [AxolotyRepositoryAuthorityFinding]) {
        guard let rootAgents = read("AGENTS.md") else {
            findings.append(.init(rule: "agents.root", path: "AGENTS.md", message: "root AGENTS.md is missing"))
            return
        }
        for marker in ["## Documentation authority", "## Normal workflow", "## Architectural invariants"] {
            if !rootAgents.contains(marker) {
                findings.append(.init(rule: "agents.root", path: "AGENTS.md", message: "root AGENTS.md must contain " + marker))
            }
        }
        if let version = read("VERSION"), rootAgents.contains(version) {
            findings.append(.init(rule: "agents.current-version", path: "AGENTS.md", message: "root AGENTS.md must not contain the current release number " + version))
        }
        for forbidden in ["/dev/tty", ".swiftpm-cache", "image digest", "connect-timeout"] where rootAgents.localizedCaseInsensitiveContains(forbidden) {
            findings.append(.init(rule: "agents.volatile", path: "AGENTS.md", message: "root AGENTS.md contains volatile operational detail: " + forbidden))
        }
        for path in ["Embedded/AGENTS.md", "Packages/AxolotyWire/AGENTS.md", "Tests/AGENTS.md", "Tools/AGENTS.md"] {
            guard let scoped = read(path) else {
                findings.append(.init(rule: "agents.scoped", path: path, message: "scoped AGENTS.md is missing"))
                continue
            }
            if !scoped.localizedCaseInsensitiveContains("instructions") || !scoped.localizedCaseInsensitiveContains("root") {
                findings.append(.init(rule: "agents.scoped", path: path, message: "scoped AGENTS.md must state its jurisdiction and relationship to root rules"))
            }
        }
    }

    private func validateArchitecture(findings: inout [AxolotyRepositoryAuthorityFinding]) -> Set<String> {
        guard let architecture = read("ARCHITECTURE.md") else { return [] }
        let ids = regexCaptures(#"`(INV-[0-9]+)`"#, in: architecture)
        let unique = Set(ids)
        if ids.count != unique.count {
            findings.append(.init(rule: "architecture.invariants", path: "ARCHITECTURE.md", message: "architecture invariant identifiers must be unique"))
        }
        if !ids.contains(Self.nonWaivableInvariant) || !architecture.contains("non-waivable") {
            findings.append(.init(rule: "architecture.invariants", path: "ARCHITECTURE.md", message: "INV-001 must be declared and marked non-waivable"))
        }
        return unique
    }

    private func validateExceptions(
        invariants: Set<String>,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        let path = "docs/architecture-exceptions.yml"
        guard let data = readData(path) else {
            findings.append(.init(rule: "exceptions.read", path: path, message: "exception ledger is missing or unreadable"))
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            findings.append(.init(rule: "exceptions.schema", path: path, message: "ledger must be JSON-compatible YAML"))
            return
        }
        guard object["schemaVersion"] as? Int == 1, let entries = object["exceptions"] as? [[String: Any]] else {
            findings.append(.init(rule: "exceptions.schema", path: path, message: "ledger requires schemaVersion 1 and an exceptions array"))
            return
        }
        var ids = Set<String>()
        for (index, entry) in entries.enumerated() {
            let prefix = "exceptions[" + String(index) + "]"
            let required = ["id", "invariant", "paths", "reason", "ownerIssue", "owner", "compensatingTests", "introducedDate", "expiry", "removalCondition"]
            for key in required where entry[key] == nil {
                findings.append(.init(rule: "exceptions.required", path: path, message: prefix + " is missing " + key))
            }
            guard let id = entry["id"] as? String, !id.isEmpty else { continue }
            if !ids.insert(id).inserted {
                findings.append(.init(rule: "exceptions.unique", path: path, message: "duplicate exception id " + id))
            }
            guard let invariant = entry["invariant"] as? String else { continue }
            if invariant == Self.nonWaivableInvariant {
                findings.append(.init(rule: "exceptions.non-waivable", path: path, message: id + " attempts to waive " + Self.nonWaivableInvariant + ", which is non-waivable"))
            } else if !invariants.contains(invariant) {
                findings.append(.init(rule: "exceptions.invariant", path: path, message: id + " names unknown invariant " + invariant))
            }
            if let paths = entry["paths"] as? [String] {
                if paths.isEmpty || paths.contains(where: { $0.isEmpty || $0.contains("*") || $0.contains("..") }) {
                    findings.append(.init(rule: "exceptions.paths", path: path, message: id + " must name non-empty exact repository paths without globs or parent traversal"))
                }
            }
            if let tests = entry["compensatingTests"] as? [String], tests.isEmpty {
                findings.append(.init(rule: "exceptions.tests", path: path, message: id + " must name compensating tests"))
            }
            validateExpiry(entry["expiry"], id: id, path: path, findings: &findings)
        }
    }

    private func validateExpiry(
        _ raw: Any?,
        id: String,
        path: String,
        findings: inout [AxolotyRepositoryAuthorityFinding]
    ) {
        guard let expiry = raw as? [String: Any], let kind = expiry["kind"] as? String, let value = expiry["value"] as? String else {
            findings.append(.init(rule: "exceptions.expiry", path: path, message: id + " requires expiry {kind: date|release, value: ...}"))
            return
        }
        if kind == "date" {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: value) else {
                findings.append(.init(rule: "exceptions.expiry", path: path, message: id + " has an invalid ISO-8601 expiry date"))
                return
            }
            if date < now {
                findings.append(.init(rule: "exceptions.expired", path: path, message: id + " is expired"))
            }
        } else if kind == "release" {
            guard isSemver(value), let current = read("VERSION").flatMap(Semver.init) else {
                findings.append(.init(rule: "exceptions.expiry", path: path, message: id + " has an invalid release expiry"))
                return
            }
            if let expiryVersion = Semver(value), expiryVersion < current {
                findings.append(.init(rule: "exceptions.expired", path: path, message: id + " expired before current VERSION " + current.description))
            }
        } else {
            findings.append(.init(rule: "exceptions.expiry", path: path, message: id + " has unsupported expiry kind " + kind))
        }
    }

    private func read(_ path: String) -> String? {
        guard let data = readData(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readData(_ path: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
    }

    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func markdownPaths() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL else { return nil }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relative.split(separator: "/").map(String.init)
            guard url.pathExtension.lowercased() == "md",
                  !components.contains(where: { [".git", ".build", "build", ".testing"].contains($0) }) else { return nil }
            return relative
        }.sorted()
    }

    private func markdownTargets(in content: String) -> [String] {
        let pattern = #"\[[^\]]*\]\((?:<([^>]+)>|([^ )]+))(?: [^)]*)?\)"#
        let matches = regexMatchGroups(pattern, in: content)
        return matches.compactMap { groups in groups.dropFirst().compactMap { $0 }.first }
    }

    private func regexCaptures(_ pattern: String, in content: String) -> [String] {
        regexMatchGroups(pattern, in: content).compactMap { $0.dropFirst().first(where: { $0 != nil }) ?? nil }
    }

    private func regexMatchGroups(_ pattern: String, in content: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let capture = match.range(at: index)
                guard capture.location != NSNotFound, let swiftRange = Range(capture, in: content) else { return nil }
                return String(content[swiftRange])
            }
        }
    }

    private func isSemver(_ value: String) -> Bool { Semver(value) != nil }
}

private struct Semver: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let pieces = value.split(separator: ".")
        guard pieces.count == 3,
              let major = Int(pieces[0]), let minor = Int(pieces[1]), let patch = Int(pieces[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { String(major) + "." + String(minor) + "." + String(patch) }
}
