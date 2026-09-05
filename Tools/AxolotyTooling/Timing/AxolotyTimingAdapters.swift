// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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

struct UnavailableTimingCacheReader: AxolotyTimingCacheStatsReading {
    func read() -> AxolotyTimingCacheSnapshot? { nil }
}
