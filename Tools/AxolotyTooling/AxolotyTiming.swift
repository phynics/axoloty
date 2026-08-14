// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The build or test operation measured by ``AxolotyTimingRunner``.
public enum AxolotyTimingScenario: String, CaseIterable, Codable, Equatable, Sendable {
    /// The host Swift package build.
    case hostBuild = "host-build"
    /// A focused Swift test build.
    case focusedTestBuild = "focused-test-build"
    /// The hardware-free Embedded Swift build.
    case embeddedBuild = "embedded-build"
    /// The hardware-free ESP-IDF linker validation.
    case linkerValidation = "linker-validation"
}

/// Whether a timing measurement starts from a fresh or reused scratch tree.
public enum AxolotyTimingMode: String, Codable, Equatable, Sendable {
    /// Remove the scenario scratch tree before running.
    case cold
    /// Reuse the scenario scratch tree created by the cold run.
    case warm
}

/// Arguments accepted by `axoloty-tool measure timing`.
public struct AxolotyTimingOptions: Codable, Equatable, Sendable {
    /// The Swift test filter used for the focused test build.
    public let filter: String
    /// An optional root for per-scenario scratch trees.
    public let scratchRoot: String?
    /// Keep scratch trees after the measurement completes.
    public let keepScratch: Bool

    /// Creates timing options.
    ///
    /// - Parameters:
    ///   - filter: Focused Swift test filter.
    ///   - scratchRoot: Optional root for isolated scenario scratch trees.
    ///   - keepScratch: Whether to retain scenario scratch trees.
    public init(
        filter: String = "AxolotyCommandDispatcherTests",
        scratchRoot: String? = nil,
        keepScratch: Bool = false
    ) {
        self.filter = filter
        self.scratchRoot = scratchRoot
        self.keepScratch = keepScratch
    }
}

/// A stable diagnostic produced while parsing timing command arguments.
public enum AxolotyTimingArgumentParserError: Codable, Equatable, Sendable {
    /// An option requiring a value was not followed by one.
    case missingValue(String)
    /// An option is not part of the timing command surface.
    case unsupportedOption(String)
    /// An option value was present but empty.
    case emptyValue(String)

    /// A stable user-facing diagnostic.
    public var message: String {
        switch self {
        case .missingValue(let option): "\(option) requires a value"
        case .unsupportedOption(let option): "unsupported timing option \(option)"
        case .emptyValue(let option): "\(option) must not be empty"
        }
    }
}

/// The success or failure of timing argument parsing.
public struct AxolotyTimingArgumentParseResult: Equatable, Sendable {
    /// Parsed options, or `nil` when parsing failed.
    public let success: AxolotyTimingOptions?
    /// A stable parse error, or `nil` on success.
    public let failure: AxolotyTimingArgumentParserError?

    init(success: AxolotyTimingOptions? = nil, failure: AxolotyTimingArgumentParserError? = nil) {
        self.success = success
        self.failure = failure
    }
}

/// Parses the argument tail of `measure timing`.
public enum AxolotyTimingArgumentParser {
    /// Parses timing options without touching the filesystem or launching a process.
    /// - Parameter arguments: The argument tail following `measure timing`.
    /// - Returns: Parsed options or one stable parse failure.
    public static func parse(_ arguments: [String]) -> AxolotyTimingArgumentParseResult {
        var filter = AxolotyTimingOptions().filter
        var scratchRoot: String?
        var keepScratch = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--filter":
                guard index + 1 < arguments.count else {
                    return AxolotyTimingArgumentParseResult(failure: .missingValue(argument))
                }
                index += 1
                guard !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    return AxolotyTimingArgumentParseResult(failure: .emptyValue(argument))
                }
                filter = arguments[index]
            case "--scratch-root":
                guard index + 1 < arguments.count else {
                    return AxolotyTimingArgumentParseResult(failure: .missingValue(argument))
                }
                index += 1
                guard !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                    return AxolotyTimingArgumentParseResult(failure: .emptyValue(argument))
                }
                scratchRoot = arguments[index]
            case "--keep-scratch":
                keepScratch = true
            default:
                return AxolotyTimingArgumentParseResult(failure: .unsupportedOption(argument))
            }
            index += 1
        }

        return AxolotyTimingArgumentParseResult(
            success: AxolotyTimingOptions(
                filter: filter,
                scratchRoot: scratchRoot,
                keepScratch: keepScratch
            )
        )
    }
}

/// A parsed integer metric, explicitly distinguishing unavailable data.
public enum AxolotyTimingMetricStatus: String, Codable, Equatable, Sendable {
    /// A value was parsed or sampled.
    case available
    /// No trustworthy value was available.
    case unavailable
}

/// A parsed integer metric, explicitly distinguishing unavailable data.
public struct AxolotyTimingMetric: Codable, Equatable, Sendable {
    /// `available` when `value` came from recognized output, otherwise `unavailable`.
    public let status: AxolotyTimingMetricStatus
    /// The parsed value, or `nil` when unavailable.
    public let value: Int?
    /// Why the value was unavailable, when applicable.
    public let diagnostic: String?

    init(value: Int, diagnostic: String? = nil) {
        status = .available
        self.value = value
        self.diagnostic = diagnostic
    }

    init(unavailable diagnostic: String) {
        status = .unavailable
        value = nil
        self.diagnostic = diagnostic
    }
}

/// Parsed cache statistics for one measurement.
public struct AxolotyTimingCacheStats: Codable, Equatable, Sendable {
    /// `available` when at least one cache counter was observed.
    public let status: AxolotyTimingMetricStatus
    /// The sum of hits and misses when both were available.
    public let value: Int?
    /// Cache hits, if reported by the command or injected reader.
    public let hits: Int?
    /// Cache misses, if reported by the command or injected reader.
    public let misses: Int?
    /// Why cache counters were unavailable, when applicable.
    public let diagnostic: String?

    init(hits: Int?, misses: Int?, diagnostic: String? = nil) {
        self.hits = hits
        self.misses = misses
        value = hits.map { $0 + (misses ?? 0) } ?? misses
        if hits != nil || misses != nil {
            status = .available
            self.diagnostic = diagnostic
        } else {
            status = .unavailable
            self.diagnostic = diagnostic ?? "cache counters were not present in command output"
        }
    }
}

/// A cache counter snapshot supplied by an injectable reader.
public struct AxolotyTimingCacheSnapshot: Codable, Equatable, Sendable {
    /// Cache hits at the time of sampling.
    public let hits: Int
    /// Cache misses at the time of sampling.
    public let misses: Int

    /// Creates a cache snapshot.
    /// - Parameters:
    ///   - hits: Cache hits at the sampling point.
    ///   - misses: Cache misses at the sampling point.
    public init(hits: Int, misses: Int) {
        self.hits = hits
        self.misses = misses
    }
}

/// Host and toolchain identity recorded with timing evidence.
public struct AxolotyTimingToolchainIdentity: Codable, Equatable, Sendable {
    /// The host platform name.
    public let platform: String
    /// The host architecture name.
    public let architecture: String
    /// The Swift toolchain identity, or `unknown` when not supplied.
    public let swiftVersion: String
    /// The ESP-IDF identity, or `unknown` when not supplied.
    public let espIDFVersion: String

    /// Creates a toolchain identity.
    /// - Parameters:
    ///   - platform: Stable host platform name.
    ///   - architecture: Stable host architecture name.
    ///   - swiftVersion: Swift compiler identity.
    ///   - espIDFVersion: ESP-IDF identity.
    public init(platform: String, architecture: String, swiftVersion: String, espIDFVersion: String) {
        self.platform = platform
        self.architecture = architecture
        self.swiftVersion = swiftVersion
        self.espIDFVersion = espIDFVersion
    }

    static func current(environment: [String: String]) -> Self {
        #if os(Linux)
        let platform = "linux"
        #else
        let platform = "macOS"
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return Self(
            platform: platform,
            architecture: architecture,
            swiftVersion: environment["SWIFT_VERSION"] ?? "unknown",
            espIDFVersion: environment["ESP_IDF_VERSION"] ?? "unknown"
        )
    }
}

/// One measured command and its parsed evidence.
public struct AxolotyTimingMeasurement: Codable, Equatable, Sendable {
    /// The operation measured.
    public let scenario: AxolotyTimingScenario
    /// The cold or warm mode.
    public let mode: AxolotyTimingMode
    /// Elapsed monotonic seconds.
    public let durationSeconds: TimeInterval
    /// The child process exit status.
    public let exitCode: Int32
    /// A bounded child diagnostic, when present.
    public let diagnostic: String?
    /// Parsed build-step evidence.
    public let buildSteps: AxolotyTimingMetric
    /// Parsed cache evidence.
    public let cache: AxolotyTimingCacheStats
    /// Whether the scenario scratch tree already existed for this run.
    public let scratchReused: Bool
    /// The scenario scratch path.
    public let scratchPath: String
    /// The exact command plan used for this measurement.
    public let command: AxolotyCommandPlan
    /// Toolchain identity for this measurement.
    public let toolchain: AxolotyTimingToolchainIdentity

    init(
        scenario: AxolotyTimingScenario,
        mode: AxolotyTimingMode,
        durationSeconds: TimeInterval,
        exitCode: Int32,
        diagnostic: String?,
        buildSteps: AxolotyTimingMetric,
        cache: AxolotyTimingCacheStats,
        scratchReused: Bool,
        scratchPath: String,
        command: AxolotyCommandPlan,
        toolchain: AxolotyTimingToolchainIdentity
    ) {
        self.scenario = scenario
        self.mode = mode
        self.durationSeconds = durationSeconds
        self.exitCode = exitCode
        self.diagnostic = diagnostic
        self.buildSteps = buildSteps
        self.cache = cache
        self.scratchReused = scratchReused
        self.scratchPath = scratchPath
        self.command = command
        self.toolchain = toolchain
    }
}

/// The complete machine-readable output of `measure timing`.
public struct AxolotyTimingReport: Codable, Equatable, Sendable {
    /// The timing evidence schema version.
    public let schemaVersion: Int
    /// The platform used to run the command.
    public let platform: AxolotyCheckPlan.Platform
    /// Toolchain identity for the run.
    public let toolchain: AxolotyTimingToolchainIdentity
    /// The root containing scenario scratch trees.
    public let scratchRoot: String
    /// Whether scratch trees were retained.
    public let keepScratch: Bool
    /// Eight serially collected measurements, or empty on unsupported platform.
    public let measurements: [AxolotyTimingMeasurement]
    /// Overall process exit status for the timing command.
    public let exitCode: Int32
    /// A bounded overall diagnostic, when applicable.
    public let diagnostic: String?

    init(
        platform: AxolotyCheckPlan.Platform,
        toolchain: AxolotyTimingToolchainIdentity,
        scratchRoot: String,
        keepScratch: Bool,
        measurements: [AxolotyTimingMeasurement],
        exitCode: Int32,
        diagnostic: String?
    ) {
        schemaVersion = 1
        self.platform = platform
        self.toolchain = toolchain
        self.scratchRoot = scratchRoot
        self.keepScratch = keepScratch
        self.measurements = measurements
        self.exitCode = exitCode
        self.diagnostic = diagnostic
    }
}

/// Parses build output without inventing unavailable metrics.
public enum AxolotyTimingOutputParser {
    /// Extracts the largest explicit `[step/total]` marker, or a count of known
    /// compile/link lines when the backend does not emit a total.
    /// - Parameter output: Captured standard output and standard error.
    /// - Returns: The parsed build-step metric or an unavailable metric.
    public static func stepMetric(from output: String) -> AxolotyTimingMetric {
        var explicitTotal = 0
        var fallbackCount = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let open = text.firstIndex(of: "["),
               let slash = text[open...].firstIndex(of: "/"),
               let close = text[slash...].firstIndex(of: "]") {
                let totalText = text[text.index(after: slash)..<close]
                if let total = Int(totalText), total > explicitTotal {
                    explicitTotal = total
                }
            }
            let lower = text.lowercased()
            if lower.contains("compiling ") || lower.contains("linking ") || lower.contains("building ") {
                fallbackCount += 1
            }
        }
        if explicitTotal > 0 { return AxolotyTimingMetric(value: explicitTotal) }
        if fallbackCount > 0 { return AxolotyTimingMetric(value: fallbackCount, diagnostic: "counted recognized build lines") }
        return AxolotyTimingMetric(unavailable: "build output contained no recognized step markers")
    }

    /// Extracts ccache hit/miss counters when present in command output.
    /// - Parameter output: Captured command output, including optional ccache statistics.
    /// - Returns: Parsed cache counters or an unavailable metric.
    public static func cacheMetric(from output: String) -> AxolotyTimingCacheStats {
        var hits: Int?
        var misses: Int?
        var splitHits = 0
        var sawSplitHits = false
        var before = AxolotyTimingCacheSnapshot(hits: 0, misses: 0)
        var after = AxolotyTimingCacheSnapshot(hits: 0, misses: 0)
        var sawBefore = false
        var sawAfter = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let lower = text.lowercased()
            let fields = lower.split(whereSeparator: \.isWhitespace)
            if fields.first == "ccache_before" || fields.first == "ccache_after" {
                guard fields.count >= 3, let value = Int(fields[2]) else { continue }
                let isBefore = fields[0] == "ccache_before"
                let key = fields[1]
                if isBefore { sawBefore = true } else { sawAfter = true }
                if key == "direct_cache_hit" || key == "preprocessed_cache_hit" || key == "cache_hit" {
                    let snapshot = isBefore ? before : after
                    let updated = AxolotyTimingCacheSnapshot(hits: snapshot.hits + value, misses: snapshot.misses)
                    if isBefore { before = updated } else { after = updated }
                } else if key == "cache_miss" {
                    let snapshot = isBefore ? before : after
                    let updated = AxolotyTimingCacheSnapshot(hits: snapshot.hits, misses: value)
                    if isBefore { before = updated } else { after = updated }
                }
                continue
            }
            if fields.first == "direct_cache_hit" || fields.first == "preprocessed_cache_hit" {
                if let value = fields.dropFirst().first.flatMap({ Int($0) }) {
                    splitHits += value
                    sawSplitHits = true
                }
            } else if lower.contains("cache hits") || lower.hasPrefix("hits:") || fields.first == "cache_hit" {
                hits = firstInteger(in: text) ?? hits
            }
            if lower.contains("cache misses") || lower.hasPrefix("misses:") || fields.first == "cache_miss" {
                misses = firstInteger(in: text) ?? misses
            }
        }
        if sawBefore, sawAfter {
            return AxolotyTimingCacheStats(
                hits: max(0, after.hits - before.hits),
                misses: max(0, after.misses - before.misses),
                diagnostic: "sampled ccache counters before and after command"
            )
        }
        if hits == nil, sawSplitHits { hits = splitHits }
        let missText = misses.map(String.init) ?? "unavailable"
        let diagnostic = hits.map { "hits=\($0) misses=\(missText)" }
        return AxolotyTimingCacheStats(hits: hits, misses: misses, diagnostic: diagnostic)
    }

    /// Bounds diagnostics so a compiler failure cannot flood JSON output.
    /// - Parameters:
    ///   - text: Diagnostic text to trim and bound.
    ///   - limit: Maximum number of characters retained.
    /// - Returns: Bounded nonempty text, or `nil` for empty input.
    public static func boundedDiagnostic(_ text: String, limit: Int = 512) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }

    private static func firstInteger(in text: String) -> Int? {
        guard let firstDigit = text.firstIndex(where: \.isNumber) else { return nil }
        let suffix = text[firstDigit...]
        let digits = suffix[firstDigit...].prefix { character in character.isNumber || character == "," }
        let normalized = String(digits).replacingOccurrences(of: ",", with: "")
        return Int(normalized)
    }
}

/// Provides a monotonic timestamp for deterministic duration calculation.
public protocol AxolotyTimingClock: Sendable {
    /// Returns monotonic seconds.
    ///
    /// - Returns: A monotonic timestamp in seconds.
    func now() -> TimeInterval
}

/// The production monotonic timing clock.
public struct AxolotyContinuousTimingClock: AxolotyTimingClock {
    /// Creates a monotonic clock.
    public init() {}

    /// Returns monotonic seconds from `DispatchTime`.
    ///
    /// - Returns: A monotonic timestamp in seconds.
    public func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// The state of one scenario scratch tree.
public struct AxolotyTimingWorkspace: Equatable, Sendable {
    /// The path used by the command.
    public let path: String
    /// Whether this run reused an existing tree.
    public let reused: Bool
    /// A bounded preparation diagnostic, when the tree was not ready.
    public let diagnostic: String?

    /// Creates workspace state.
    /// - Parameters:
    ///   - path: Scenario-specific mutable scratch path.
    ///   - reused: Whether the path existed for the warm run.
    ///   - diagnostic: A bounded preparation failure diagnostic.
    public init(path: String, reused: Bool = false, diagnostic: String? = nil) {
        self.path = path
        self.reused = reused
        self.diagnostic = diagnostic
    }
}

/// Owns per-scenario scratch directories and cleanup.
public protocol AxolotyTimingWorkspaceManaging: Sendable {
    /// Prepares one scenario's cold or warm directory.
    ///
    /// - Parameters:
    ///   - root: Root containing isolated scenario directories.
    ///   - scenario: Scenario whose directory is prepared.
    ///   - mode: Whether to clear or reuse the directory.
    /// - Returns: Prepared workspace state.
    func prepare(root: String, scenario: AxolotyTimingScenario, mode: AxolotyTimingMode) -> AxolotyTimingWorkspace
    /// Removes one scenario directory when scratch retention is disabled.
    ///
    /// - Parameter workspace: Workspace to remove.
    /// - Returns: A stable diagnostic if cleanup fails, otherwise `nil`.
    func cleanup(_ workspace: AxolotyTimingWorkspace) -> String?
}

/// A Foundation-backed workspace manager.
public struct FoundationTimingWorkspaceManager: AxolotyTimingWorkspaceManaging {
    /// Creates a Foundation workspace manager.
    public init() {}

    /// Creates or reuses the scenario directory.
    ///
    /// - Parameters:
    ///   - root: Root containing isolated scenario directories.
    ///   - scenario: Scenario whose directory is prepared.
    ///   - mode: Whether to clear or reuse the directory.
    /// - Returns: Prepared workspace state with a stable failure diagnostic.
    public func prepare(root: String, scenario: AxolotyTimingScenario, mode: AxolotyTimingMode) -> AxolotyTimingWorkspace {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let scenarioURL = rootURL.appendingPathComponent(scenario.rawValue, isDirectory: true)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let existed = fileManager.fileExists(atPath: scenarioURL.path)
            if mode == .cold, existed {
                try fileManager.removeItem(at: scenarioURL)
            }
            try fileManager.createDirectory(at: scenarioURL, withIntermediateDirectories: true)
            return AxolotyTimingWorkspace(path: scenarioURL.path, reused: mode == .warm && existed)
        } catch {
            return AxolotyTimingWorkspace(
                path: scenarioURL.path,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(
                    "unable to prepare timing scratch directory \(scenarioURL.path): \(String(reflecting: error))"
                )
            )
        }
    }

    /// Removes a prepared scenario directory.
    ///
    /// - Parameter workspace: Workspace to remove.
    public func cleanup(_ workspace: AxolotyTimingWorkspace) -> String? {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return nil }
        do {
            try FileManager.default.removeItem(atPath: workspace.path)
            return nil
        } catch {
            return AxolotyTimingOutputParser.boundedDiagnostic(
                "unable to remove timing scratch directory \(workspace.path): \(String(reflecting: error))"
            )
        }
    }
}

/// Reads cache counters independently of command output.
public protocol AxolotyTimingCacheStatsReading: Sendable {
    /// Returns a counter snapshot, or `nil` when the cache backend is unavailable.
    ///
    /// - Returns: Current counters, or `nil` when unavailable.
    func read() -> AxolotyTimingCacheSnapshot?
}

private struct UnavailableTimingCacheReader: AxolotyTimingCacheStatsReading {
    func read() -> AxolotyTimingCacheSnapshot? { nil }
}

/// Runs the explicit, serial, hardware-free timing evidence command.
public struct AxolotyTimingRunner: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let environment: [String: String]
    private let platform: AxolotyCheckPlan.Platform
    private let workspace: any AxolotyTimingWorkspaceManaging
    private let clock: any AxolotyTimingClock
    private let cacheReader: any AxolotyTimingCacheStatsReading
    private let identity: AxolotyTimingToolchainIdentity

    /// Creates a timing runner with injectable process, clock, workspace, and cache seams.
    ///
    /// - Parameters:
    ///   - commandRunner: Process runner used for each serialized measurement.
    ///   - environment: Environment used to resolve the manifest and defaults.
    ///   - platform: Platform boundary for Linux-only measurements.
    ///   - workspace: Isolated scratch-directory manager.
    ///   - clock: Monotonic timing source.
    ///   - cacheReader: Optional externally sampled cache-counter source.
    ///   - identity: Optional deterministic toolchain identity.
    public init(
        commandRunner: any AxolotyCheckCommandRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform,
        workspace: any AxolotyTimingWorkspaceManaging = FoundationTimingWorkspaceManager(),
        clock: any AxolotyTimingClock = AxolotyContinuousTimingClock(),
        cacheReader: (any AxolotyTimingCacheStatsReading)? = nil,
        identity: AxolotyTimingToolchainIdentity? = nil
    ) {
        self.commandRunner = commandRunner
        self.environment = environment
        self.platform = platform
        self.workspace = workspace
        self.clock = clock
        self.cacheReader = cacheReader ?? UnavailableTimingCacheReader()
        self.identity = identity ?? AxolotyTimingToolchainIdentity.current(environment: environment)
    }

    /// Runs cold and warm measurements for each supported scenario in stable order.
    ///
    /// - Parameter options: Timing filter and scratch-retention options.
    /// - Returns: Complete machine-readable evidence report.
    public func run(_ options: AxolotyTimingOptions) -> AxolotyTimingReport {
        let root = options.scratchRoot
            ?? environment["AXOLOTY_TIMING_SCRATCH_ROOT"]
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".testing/timing", isDirectory: true).path
        guard platform == .linux else {
            return AxolotyTimingReport(
                platform: platform,
                toolchain: identity,
                scratchRoot: root,
                keepScratch: options.keepScratch,
                measurements: [],
                exitCode: 69,
                diagnostic: "measure timing is supported only on Linux"
            )
        }
        let manifest: AxolotyCanonicalTestManifest
        do {
            manifest = try AxolotyCanonicalTestManifest.loadDefault(environment: environment)
        } catch let error as AxolotyCanonicalTestManifestError {
            return AxolotyTimingReport(
                platform: platform,
                toolchain: identity,
                scratchRoot: root,
                keepScratch: options.keepScratch,
                measurements: [],
                exitCode: 70,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(error.userFriendlyMessage)
            )
        } catch {
            return AxolotyTimingReport(
                platform: platform,
                toolchain: identity,
                scratchRoot: root,
                keepScratch: options.keepScratch,
                measurements: [],
                exitCode: 70,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(
                    "unable to load the canonical test manifest: \(String(reflecting: error))"
                )
            )
        }

        var measurements: [AxolotyTimingMeasurement] = []
        var cleanupDiagnostics: [String] = []
        for scenario in AxolotyTimingScenario.allCases {
            for mode in [AxolotyTimingMode.cold, .warm] {
                let prepared = workspace.prepare(root: root, scenario: scenario, mode: mode)
                let measurement = measure(
                    scenario: scenario,
                    mode: mode,
                    workspace: prepared,
                    manifest: manifest,
                    filter: options.filter
                )
                measurements.append(measurement)
            }
            if !options.keepScratch, let workspaceState = measurements.last(where: { $0.scenario == scenario }) {
                if let diagnostic = workspace.cleanup(AxolotyTimingWorkspace(path: workspaceState.scratchPath)) {
                    cleanupDiagnostics.append(diagnostic)
                }
            }
        }
        let measurementFailed = measurements.contains { $0.exitCode != 0 }
        let failed = measurementFailed || !cleanupDiagnostics.isEmpty
        let diagnostic: String? = if !cleanupDiagnostics.isEmpty {
            AxolotyTimingOutputParser.boundedDiagnostic(cleanupDiagnostics.joined(separator: "; "))
        } else if measurementFailed {
            "one or more timing measurements failed"
        } else {
            nil
        }
        return AxolotyTimingReport(
            platform: platform,
            toolchain: identity,
            scratchRoot: root,
            keepScratch: options.keepScratch,
            measurements: measurements,
            exitCode: failed ? 1 : 0,
            diagnostic: diagnostic
        )
    }

    private func measure(
        scenario: AxolotyTimingScenario,
        mode: AxolotyTimingMode,
        workspace: AxolotyTimingWorkspace,
        manifest: AxolotyCanonicalTestManifest,
        filter: String
    ) -> AxolotyTimingMeasurement {
        let commandResult = commandPlan(
            scenario: scenario,
            workspace: workspace.path,
            manifest: manifest,
            filter: filter,
            mode: mode
        )
        let command: AxolotyCommandPlan
        switch commandResult {
        case .success(let plan):
            command = plan
        case .failure(let error):
            return AxolotyTimingMeasurement(
                scenario: scenario, mode: mode, durationSeconds: 0, exitCode: 70,
                diagnostic: AxolotyTimingOutputParser.boundedDiagnostic(error.userFriendlyMessage),
                buildSteps: AxolotyTimingMetric(unavailable: "command unavailable"),
                cache: AxolotyTimingCacheStats(hits: nil, misses: nil),
                scratchReused: workspace.reused, scratchPath: workspace.path,
                command: AxolotyCommandPlan(executable: "unavailable"), toolchain: identity
            )
        }
        guard workspace.diagnostic == nil else {
            return AxolotyTimingMeasurement(
                scenario: scenario, mode: mode, durationSeconds: 0, exitCode: 70,
                diagnostic: workspace.diagnostic,
                buildSteps: AxolotyTimingMetric(unavailable: "workspace unavailable"),
                cache: AxolotyTimingCacheStats(hits: nil, misses: nil),
                scratchReused: workspace.reused, scratchPath: workspace.path,
                command: command, toolchain: identity
            )
        }
        let before = cacheReader.read()
        let start = clock.now()
        let result = commandRunner.run(command)
        let duration = max(0, clock.now() - start)
        let after = cacheReader.read()
        let output = result.standardOutput + "\n" + result.standardError
        let cache = cacheStats(before: before, after: after, output: output)
        return AxolotyTimingMeasurement(
            scenario: scenario,
            mode: mode,
            durationSeconds: duration,
            exitCode: result.exitCode,
            diagnostic: result.exitCode == 0
                ? nil
                : AxolotyTimingOutputParser.boundedDiagnostic(result.standardError.isEmpty ? result.standardOutput : result.standardError),
            buildSteps: AxolotyTimingOutputParser.stepMetric(from: output),
            cache: cache,
            scratchReused: workspace.reused,
            scratchPath: workspace.path,
            command: command,
            toolchain: identity
        )
    }

    private func commandPlan(
        scenario: AxolotyTimingScenario,
        workspace: String,
        manifest: AxolotyCanonicalTestManifest,
        filter: String,
        mode: AxolotyTimingMode
    ) -> Result<AxolotyCommandPlan, AxolotyCanonicalTestManifestError> {
        let baseResult: Result<AxolotyCommandPlan, AxolotyCanonicalTestManifestError>
        switch scenario {
        case .hostBuild:
            baseResult = canonicalCommand(named: "build", in: manifest)
        case .focusedTestBuild:
            baseResult = .success(manifest.testOneCommand(filter: filter))
        case .embeddedBuild:
            baseResult = canonicalCommand(named: "embedded-build", in: manifest)
        case .linkerValidation:
            baseResult = canonicalCommand(named: "embedded-linker", in: manifest)
        }
        let base: AxolotyCommandPlan
        switch baseResult {
        case .success(let plan): base = plan
        case .failure(let error): return .failure(error)
        }
        var arguments = base.arguments
        var commandEnvironment = base.environment
        commandEnvironment["AXOLOTY_TIMING_SCENARIO"] = scenario.rawValue
        commandEnvironment["AXOLOTY_TIMING_MODE"] = mode.rawValue
        commandEnvironment["AXOLOTY_TIMING_SCRATCH"] = workspace
        switch scenario {
        case .hostBuild, .focusedTestBuild:
            if !arguments.contains("--scratch-path") {
                arguments += ["--scratch-path", workspace]
            }
        case .embeddedBuild:
            commandEnvironment["EMBEDDED_BUILD_DIR"] = workspace
            commandEnvironment["AXOLOTY_TIMING_EVIDENCE"] = "1"
        case .linkerValidation:
            commandEnvironment["AXOLOTY_EMBEDDED_LINKER_BUILD_DIR"] = workspace
            commandEnvironment["AXOLOTY_TIMING_EVIDENCE"] = "1"
        }
        return .success(AxolotyCommandPlan(
            executable: base.executable,
            arguments: arguments,
            environment: commandEnvironment,
            executionContext: base.executionContext,
            timeoutSeconds: base.timeoutSeconds
        ))
    }

    private func canonicalCommand(
        named name: String,
        in manifest: AxolotyCanonicalTestManifest
    ) -> Result<AxolotyCommandPlan, AxolotyCanonicalTestManifestError> {
        do {
            let node = try manifest.node(named: name)
            return .success(node.command.commandPlan(timeoutSeconds: node.timeoutSeconds))
        } catch let error as AxolotyCanonicalTestManifestError {
            return .failure(error)
        } catch {
            return .failure(.invalidPlan(
                name: name,
                reason: "unexpected canonical manifest error: \(String(reflecting: error))"
            ))
        }
    }

    private func cacheStats(
        before: AxolotyTimingCacheSnapshot?,
        after: AxolotyTimingCacheSnapshot?,
        output: String
    ) -> AxolotyTimingCacheStats {
        if let before, let after {
            return AxolotyTimingCacheStats(
                hits: max(0, after.hits - before.hits),
                misses: max(0, after.misses - before.misses),
                diagnostic: "sampled before and after command"
            )
        }
        return AxolotyTimingOutputParser.cacheMetric(from: output)
    }
}
