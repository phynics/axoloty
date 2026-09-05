// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// The outcome status of a hardware check.
public enum AxolotyHardwareStatus: String, Codable, Equatable, Sendable {
    /// The check was successful.
    case passed
    /// The device was absent and the check was not run.
    case skipped
    /// The device was present but the check failed.
    case failed
}

/// A structured result from an embedded hardware check.
public struct AxolotyHardwareOutcome: Codable, Equatable, Sendable {
    /// The check outcome.
    public let status: AxolotyHardwareStatus
    /// The selected device path.
    public let device: String
    /// The reason for the outcome.
    public let reason: String

    /// Creates a hardware outcome.
    public init(status: AxolotyHardwareStatus, device: String, reason: String) {
        self.status = status
        self.device = device
        self.reason = reason
    }
}

/// The filesystem boundary used by hardware checks.
public protocol AxolotyFileSystem: Sendable {
    /// Returns whether a path exists.
    func exists(atPath path: String) -> Bool

    /// Reads a UTF-8 text file when the path is available.
    ///
    /// Implementations used by command tests may omit file contents; the
    /// default returns `nil` so existence-only callers remain source
    /// compatible.
    func contents(atPath path: String) -> String?
}

public extension AxolotyFileSystem {
    func contents(atPath path: String) -> String? { nil }
}

struct FoundationFileSystem: AxolotyFileSystem {
    init() {}
    func exists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func contents(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

/// The standard streams and status produced by an ``AxolotyCommandDispatcher``.
public struct AxolotyCommandResult: Equatable, Sendable {
    /// Text to write to standard output.
    public let standardOutput: String

    /// Text to write to standard error.
    public let standardError: String

    /// Process status to return to the caller.
    public let exitCode: Int32

    /// Creates a command result.
    ///
    /// - Parameters:
    ///   - standardOutput: Text to write to standard output.
    ///   - standardError: Text to write to standard error.
    ///   - exitCode: Process status to return to the caller.
    public init(
        standardOutput: String = "",
        standardError: String = "",
        exitCode: Int32 = 0
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}
