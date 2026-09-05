// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
