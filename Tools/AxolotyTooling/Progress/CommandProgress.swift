// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A recognizable execution phase within a long-running command.
public enum AxolotyCommandPhase: String, Codable, Equatable, Sendable {
    /// Preparing build inputs or scratch state.
    case preparing
    /// Resolving package or dependency graphs.
    case resolving
    /// Planning a build before compilation begins.
    case planning
    /// Compiling translation units or modules.
    case compiling
    /// Emitting a compiled module.
    case emittingModule
    /// Linking a product.
    case linking
    /// Running tests.
    case testing
    /// Starting a service or long-lived process.
    case startingService
    /// Waiting for an external condition.
    case waiting
    /// Running an unclassified workload.
    case running
    /// The work completed successfully.
    case completed
}

/// Pass, fail, and skip counters observed for a test run.
public struct AxolotyCommandProgressCounters: Equatable, Sendable {
    /// Tests observed as passed.
    public var passed: Int
    /// Tests observed as failed.
    public var failed: Int
    /// Tests observed as skipped.
    public var skipped: Int

    /// Creates test progress counters.
    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }
}

/// Useful progress extracted from one or more subprocess output lines.
///
/// Every field is optional: unknown commands must remain representable and
/// the model must never invent information that cannot be reliably parsed.
public struct AxolotyCommandProgress: Equatable, Sendable {
    /// The execution phase the line indicates.
    public let phase: AxolotyCommandPhase?
    /// The completed step count when the tool emitted one.
    public let completed: Int?
    /// The total step count when the tool emitted one.
    public let total: Int?
    /// The target, module, or suite currently being processed.
    public let target: String?
    /// A current file, test, or other detail when the tool emitted one.
    public let detail: String?
    /// Observed test counters, when the command is a test run.
    public let counters: AxolotyCommandProgressCounters?

    /// Creates parsed progress.
    ///
    /// - Parameters:
    ///   - phase: The execution phase the line indicates.
    ///   - completed: The completed step count when the tool emitted one.
    ///   - total: The total step count when the tool emitted one.
    ///   - target: The target or suite currently being processed.
    ///   - detail: A current file or test detail when the tool emitted one.
    ///   - counters: Observed test counters, when the command is a test run.
    public init(
        phase: AxolotyCommandPhase? = nil,
        completed: Int? = nil,
        total: Int? = nil,
        target: String? = nil,
        detail: String? = nil,
        counters: AxolotyCommandProgressCounters? = nil
    ) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.target = target
        self.detail = detail
        self.counters = counters
    }

    /// The known progress fraction, or `nil` when no total is known.
    ///
    /// Fake percentages are never produced: a fraction exists only when both
    /// a completed count and a positive total were actually observed.
    public var fraction: Double? {
        guard let completed, let total, total > 0, completed >= 0, completed <= total else { return nil }
        return Double(completed) / Double(total)
    }
}
