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
        let semanticVersion = #"([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)"#
        let claims: [(String, String, Bool)] = [
            ("README.md", "from: \"" + semanticVersion + "\"", true),
            ("Source/Axoloty.docc/GettingStarted.md", "from: \"" + semanticVersion + "\"", true),
            ("Makefile", "AXOLOTY_CONSUMER_VERSION \\?= " + semanticVersion, false),
            ("Tests/Support/check-axoloty-semver-consumer.sh", "version=.*:-" + semanticVersion + "\\}", false),
            ("Tools/AxolotyTooling/AxolotyCommandDispatcher.swift", "private static let version = \"" + semanticVersion + "\"", false),
            ("Tools/AxolotyInspectorCore/InspectorArgumentParser.swift", "public static let version = \"" + semanticVersion + "\"", false),
            ("Tools/AxolotyToolingTests/AxolotyCommandDispatcherTests.swift", "axoloty-tool " + semanticVersion, true),
            ("Tools/AxolotyToolingTests/AxolotyServeParserTests.swift", "(?:ax|axoloty-tool) " + semanticVersion, true),
            ("Tools/AxolotyInspectorCoreTests/InspectorArgumentParserTests.swift", "version == \"" + semanticVersion + "\"", true),
            ("docs/API.md", "Axoloty " + semanticVersion, true),
            ("docs/SUPPORT_MATRIX.md", "(?:Axoloty )?" + semanticVersion + " (?:support matrix|checkpoint)", true),
            ("docs/ROADMAP.md", "current released version \\(`" + semanticVersion + "`\\)", false),
            ("docs/FEATURE_MATRIX.md", "full " + semanticVersion + " support", false),
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
                if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") {
                    continue
                }
                let pieces = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let withoutFragment = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
                let fragment = pieces.count == 2 ? String(pieces[1]) : nil
                let base = root.appendingPathComponent(path).deletingLastPathComponent()
                let resolved = withoutFragment.isEmpty
                    ? root.appendingPathComponent(path)
                    : URL(fileURLWithPath: withoutFragment, relativeTo: base).standardizedFileURL
                guard isWithinRepository(resolved) else {
                    findings.append(.init(rule: "links.scope", path: path, message: "link escapes the repository: " + target))
                    continue
                }
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    findings.append(.init(rule: "links.resolve", path: path, message: "link target does not exist: " + target))
                } else if let fragment, !fragment.isEmpty, resolved.pathExtension.lowercased() == "md",
                          let destination = try? String(contentsOf: resolved, encoding: .utf8),
                          !markdownAnchors(in: destination).contains(fragment.lowercased()) {
                    findings.append(.init(rule: "links.anchor", path: path, message: "link heading does not exist: " + target))
                }
            }
            if path.contains(".docc/") {
                for target in doccArticleTargets(in: content) where !doccArticleNames().contains(target) {
                    findings.append(.init(rule: "links.docc.resolve", path: path, message: "DocC article does not exist: <doc:" + target + ">"))
                }
            }
        }
    }

    private func validateAgents(findings: inout [AxolotyRepositoryAuthorityFinding]) {
        guard let rootAgents = read("AGENTS.md") else {
            findings.append(.init(rule: "agents.root", path: "AGENTS.md", message: "root AGENTS.md is missing"))
            return
        }
        for marker in [
            "## Jurisdiction", "## Documentation authority", "## Architectural invariants",
            "## Supported workflow", "## Prohibited shortcuts", "## Authority links",
        ] {
            if !rootAgents.contains(marker) {
                findings.append(.init(rule: "agents.root", path: "AGENTS.md", message: "root AGENTS.md must contain " + marker))
            }
        }
        if !regexCaptures(#"\b(v?[0-9]+\.[0-9]+(?:\.[0-9]+)?)\b"#, in: rootAgents).isEmpty {
            findings.append(.init(rule: "agents.release-number", path: "AGENTS.md", message: "root AGENTS.md must not contain release numbers"))
        }
        let volatileDetails = [
            "/dev/", "/workspace", "/opt/", "/tmp/", ".cache/", ".swiftpm-cache",
            ".devcontainer", "BUILD_DIR", "SPM_CACHE", "CONTAINER_DEVICES", "image digest",
            "connect-timeout", "timeoutSeconds", "podman run", "docker run",
        ]
        for forbidden in volatileDetails where rootAgents.localizedCaseInsensitiveContains(forbidden) {
            findings.append(.init(rule: "agents.volatile", path: "AGENTS.md", message: "root AGENTS.md contains volatile operational detail: " + forbidden))
        }
        let scopes = ["Embedded", "Packages/AxolotyWire", "Tests", "Tools"]
        for scope in scopes {
            let path = scope + "/AGENTS.md"
            guard let scoped = read(path) else {
                findings.append(.init(rule: "agents.scoped", path: path, message: "scoped AGENTS.md is missing"))
                continue
            }
            let rootLink = scope == "Packages/AxolotyWire"
                ? "The root [`AGENTS.md`](../../AGENTS.md) rules apply"
                : "The root [`AGENTS.md`](../AGENTS.md) rules apply"
            if !scoped.contains("## Jurisdiction") || !scoped.contains("## Specialized rules") ||
                !scoped.contains("This guide applies to `" + scope + "/`.") || !scoped.contains(rootLink) {
                findings.append(.init(rule: "agents.scoped", path: path, message: "scoped AGENTS.md must declare its exact jurisdiction and specialized root rules"))
            }
        }
    }

    private func validateArchitecture(findings: inout [AxolotyRepositoryAuthorityFinding]) -> Set<String> {
        guard let architecture = read("ARCHITECTURE.md") else { return [] }
        // Only declaration bullets establish invariant identifiers. References
        // in explanatory prose must not be mistaken for duplicate declarations.
        let ids = regexCaptures(#"^- `?(INV-[0-9]+)`?"#, in: architecture)
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
        guard object["schemaVersion"] as? Int == 1, let rawEntries = object["exceptions"] as? [Any] else {
            findings.append(.init(rule: "exceptions.schema", path: path, message: "ledger requires schemaVersion 1 and an exceptions array"))
            return
        }
        var ids = Set<String>()
        for (index, rawEntry) in rawEntries.enumerated() {
            let prefix = "exceptions[" + String(index) + "]"
            guard let entry = rawEntry as? [String: Any] else {
                findings.append(.init(rule: "exceptions.schema", path: path, message: prefix + " must be an object"))
                continue
            }
            let required = ["id", "invariant", "paths", "reason", "ownerIssue", "owner", "compensatingTests", "introducedDate", "expiry", "removalCondition"]
            for key in required where entry[key] == nil {
                findings.append(.init(rule: "exceptions.required", path: path, message: prefix + " is missing " + key))
            }
            guard let id = nonEmptyString(entry["id"]) else {
                findings.append(.init(rule: "exceptions.value", path: path, message: prefix + ".id must be a non-empty string"))
                continue
            }
            if !ids.insert(id).inserted {
                findings.append(.init(rule: "exceptions.unique", path: path, message: "duplicate exception id " + id))
            }
            if let invariant = nonEmptyString(entry["invariant"]), invariant == Self.nonWaivableInvariant {
                findings.append(.init(rule: "exceptions.non-waivable", path: path, message: id + " attempts to waive " + Self.nonWaivableInvariant + ", which is non-waivable"))
            } else if let invariant = nonEmptyString(entry["invariant"]), !invariants.contains(invariant) {
                findings.append(.init(rule: "exceptions.invariant", path: path, message: id + " names unknown invariant " + invariant))
            } else if nonEmptyString(entry["invariant"]) == nil {
                findings.append(.init(rule: "exceptions.value", path: path, message: id + ".invariant must be a non-empty string"))
            }
            if let paths = entry["paths"] as? [String] {
                if paths.isEmpty || paths.contains(where: { !isExactExistingRepositoryFile($0) }) {
                    findings.append(.init(rule: "exceptions.paths", path: path, message: id + " must name non-empty exact repository file paths without globs or parent traversal"))
                }
            } else {
                findings.append(.init(rule: "exceptions.paths", path: path, message: id + ".paths must be an array of exact repository paths"))
            }
            if let tests = entry["compensatingTests"] as? [String],
               !tests.isEmpty, tests.allSatisfy({ isCompensatingTestReference($0) }) {
                // Validated above; an optional fragment names a test within the file.
            } else {
                findings.append(.init(rule: "exceptions.tests", path: path, message: id + " must name existing compensating-test paths"))
            }
            for key in ["reason", "owner", "removalCondition"] where nonEmptyString(entry[key]) == nil {
                findings.append(.init(rule: "exceptions.value", path: path, message: id + "." + key + " must be a non-empty string"))
            }
            guard let ownerIssue = nonEmptyString(entry["ownerIssue"]), knownOwnerIssues().contains(ownerIssue) else {
                findings.append(.init(rule: "exceptions.issue", path: path, message: id + ".ownerIssue must identify an issue linked from current repository documentation"))
                validateIntroducedDate(entry["introducedDate"], id: id, path: path, findings: &findings)
                validateExpiry(entry["expiry"], id: id, path: path, findings: &findings)
                continue
            }
            validateIntroducedDate(entry["introducedDate"], id: id, path: path, findings: &findings)
            validateExpiry(entry["expiry"], id: id, path: path, findings: &findings)
        }
    }

    private func validateIntroducedDate(_ raw: Any?, id: String, path: String, findings: inout [AxolotyRepositoryAuthorityFinding]) {
        guard let value = nonEmptyString(raw), let date = repositoryDate(value) else {
            findings.append(.init(rule: "exceptions.introduced-date", path: path, message: id + " requires introducedDate in YYYY-MM-DD form"))
            return
        }
        if date > now {
            findings.append(.init(rule: "exceptions.introduced-date", path: path, message: id + " has a future introducedDate"))
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
            guard let date = repositoryDate(value) else {
                findings.append(.init(rule: "exceptions.expiry", path: path, message: id + " has an invalid YYYY-MM-DD expiry date"))
                return
            }
            if date < now {
                findings.append(.init(rule: "exceptions.expired", path: path, message: id + " is expired"))
            }
        } else if kind == "release" {
            let currentVersion = read("VERSION")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSemver(value), let current = currentVersion.flatMap(Semver.init) else {
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

    private func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func isExactExistingRepositoryFile(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("*"), !path.contains("?"), !path.contains("["), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        return isWithinRepository(resolved) &&
            FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) &&
            !isDirectory.boolValue
    }

    private func isCompensatingTestReference(_ reference: String) -> Bool {
        let pieces = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        guard isExactExistingRepositoryFile(path) else { return false }
        let components = path.split(separator: "/").map(String.init)
        let isTestLocation = components.first == "Tests" || components.contains("Tests")
        let allowedExtensions = Set(["swift", "sh", "mjs", "js"])
        return isTestLocation && allowedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func knownOwnerIssues() -> Set<String> {
        let pattern = #"https://github\.com/phynics/axoloty/issues/([1-9][0-9]*)"#
        let planningDocuments = markdownPaths().filter {
            $0 == "ARCHITECTURE.md" || $0 == "docs/ROADMAP.md" || $0.hasPrefix("docs/adr/")
        }
        return Set(planningDocuments.flatMap { path in
            read(path).map { regexCaptures(pattern, in: $0).map { "#" + $0 } } ?? []
        })
    }

    private func isWithinRepository(_ url: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
    }

    private func repositoryDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    private func markdownPaths() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let generatedDirectories: Set<String> = [
            ".build", ".git", ".swiftpm-cache", ".testing", ".worktree", "build", "node_modules"
        ]
        var paths: [String] = []
        for case let url as URL in enumerator {
            if generatedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let components = relative.split(separator: "/").map(String.init)
            guard url.pathExtension.lowercased() == "md",
                  !components.contains(where: generatedDirectories.contains),
                  !relative.hasPrefix("docs/releases/"),
                  !relative.hasPrefix("docs/migration/") else { continue }
            paths.append(relative)
        }
        return paths.sorted()
    }

    private func markdownTargets(in content: String) -> [String] {
        let pattern = #"\[[^\]]*\]\((?:<([^>]+)>|([^ )]+))(?: [^)]*)?\)"#
        let matches = regexMatchGroups(pattern, in: content)
        return matches.compactMap { groups in groups.dropFirst().compactMap { $0 }.first }
    }

    private func markdownAnchors(in content: String) -> Set<String> {
        let headings = regexCaptures(#"^#{1,6}\s+(.+?)\s*#*$"#, in: content)
        return Set(headings.map { heading in
            heading.lowercased()
                .replacingOccurrences(of: #"[`*_~]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[^a-z0-9 -]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        })
    }

    private func doccArticleTargets(in content: String) -> [String] {
        regexCaptures(#"<doc:([^>]+)>"#, in: content)
    }

    private func doccArticleNames() -> Set<String> {
        Set(markdownPaths().filter { $0.contains(".docc/") }.flatMap { path in
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return [stem, stem + "-article"]
        })
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
    let prerelease: [String]
    let original: String

    init?(_ value: String) {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.range == NSRange(value.startIndex..<value.endIndex, in: value),
              let majorRange = Range(match.range(at: 1), in: value),
              let minorRange = Range(match.range(at: 2), in: value),
              let patchRange = Range(match.range(at: 3), in: value),
              let major = Int(value[majorRange]), let minor = Int(value[minorRange]), let patch = Int(value[patchRange]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if match.range(at: 4).location == NSNotFound {
            prerelease = []
        } else if let prereleaseRange = Range(match.range(at: 4), in: value) {
            prerelease = value[prereleaseRange].split(separator: ".").map(String.init)
        } else {
            return nil
        }
        original = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = (lhs.major, lhs.minor, lhs.patch)
        let rhsCore = (rhs.major, rhs.minor, rhs.patch)
        if lhsCore != rhsCore { return lhsCore < rhsCore }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    var description: String { original }
}
