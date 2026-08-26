// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// swiftlint:disable file_length function_parameter_count optional_data_string_conversion
public enum AxolotyCommandOutputMode: String, Codable, Equatable, Sendable {
    /// Keep command standard output available for the final machine result.
    case json
    /// Forward command output to the terminal as it is produced.
    case human
}
// swiftlint:enable file_length function_parameter_count optional_data_string_conversion

/// Identifies the stream from which a live command output event originated.
public enum AxolotyCommandOutputStream: String, Codable, Equatable, Sendable {
    /// Standard output from the child command.
    case standardOutput = "stdout"
    /// Standard error from the child command, or runner progress diagnostics.
    case standardError = "stderr"
}

/// Describes the check node and stage currently owned by a command runner.
public struct AxolotyCommandRunContext: Codable, Equatable, Sendable {
    /// The check node owning the command, when the command belongs to a plan.
    public let node: String?
    /// The lifecycle stage in which the command is running.
    public let stage: String

    /// Creates a command run context.
    ///
    /// - Parameters:
    ///   - node: The owning check node, if known.
    ///   - stage: A stable lifecycle stage label.
    public init(node: String? = nil, stage: String = "command") {
        self.node = node
        self.stage = stage
    }
}

/// The terminal state recorded for a command lifecycle.
public enum AxolotyCommandLifecycleOutcome: String, Codable, Equatable, Sendable {
    /// The command exceeded its deadline.
    case timedOut
    /// The command was cancelled by its owner.
    case cancelled
}

/// Structured diagnostics attached to a command that did not complete normally.
public struct AxolotyCommandLifecycle: Codable, Equatable, Sendable {
    /// The lifecycle outcome.
    public let outcome: AxolotyCommandLifecycleOutcome
    /// The check node that owned the command.
    public let node: String?
    /// The lifecycle stage in which the command ran.
    public let stage: String
    /// Elapsed wall-clock time until the command was reaped.
    public let elapsedSeconds: Double
    /// The absolute deadline, formatted as ISO 8601, when one was configured.
    public let deadline: String?
    /// The latest Swift Testing started line observed on either output stream.
    public let lastTest: String?
    /// The durable command artifact directory.
    public let artifactPath: String?
    /// Whether the bounded grace period required SIGKILL escalation.
    public let escalatedToKill: Bool

    /// Creates lifecycle diagnostics.
    public init(
        outcome: AxolotyCommandLifecycleOutcome,
        node: String? = nil,
        stage: String = "command",
        elapsedSeconds: Double,
        deadline: String? = nil,
        lastTest: String? = nil,
        artifactPath: String? = nil,
        escalatedToKill: Bool = false
    ) {
        self.outcome = outcome
        self.node = node
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
        self.deadline = deadline
        self.lastTest = lastTest
        self.artifactPath = artifactPath
        self.escalatedToKill = escalatedToKill
    }
}

public struct AxolotyCommandRunnerConfiguration: Sendable {
    /// The maximum wall-clock time for each command, or `nil` for no deadline.
    public let commandTimeout: TimeInterval?
    /// The grace period between SIGTERM and SIGKILL.
    public let terminationGracePeriod: TimeInterval
    /// The interval between progress heartbeats.
    public let heartbeatInterval: TimeInterval
    /// The live-output policy.
    public let outputMode: AxolotyCommandOutputMode
    /// The root directory for durable run artifacts.
    public let artifactRoot: URL
    /// An optional externally supplied run identifier.
    public let runID: String?
    /// Whether the invocation owns SIGINT/SIGTERM handling.
    ///
    /// The dispatcher consumes this setting once per invocation. The command
    /// runner never installs process-global handlers per command.
    public let installSignalHandler: Bool
    /// Receives live command output and heartbeat lines.
    public let streamOutput: @Sendable (AxolotyCommandOutputStream, String) -> Void
    /// A configuration validation diagnostic, when supplied durations are invalid.
    public let validationDiagnostic: AxolotyCommandLifecycleDiagnostic?

    /// Creates command-runner configuration.
    ///
    /// - Parameters:
    ///   - commandTimeout: Per-command timeout in seconds. `nil` disables it.
    ///   - terminationGracePeriod: Bounded TERM-to-KILL grace period in seconds.
    ///   - heartbeatInterval: Progress heartbeat interval in seconds.
    ///   - outputMode: The live-output policy.
    ///   - artifactRoot: Root for durable run directories.
    ///   - runID: Optional run identifier. A UUID is generated when absent.
    ///   - installSignalHandler: Whether to forward process signals into cancellation.
    ///   - streamOutput: Sink for live output and progress diagnostics.
    public init(
        commandTimeout: TimeInterval? = 30 * 60,
        terminationGracePeriod: TimeInterval = 2,
        heartbeatInterval: TimeInterval = 5,
        outputMode: AxolotyCommandOutputMode = .json,
        artifactRoot: URL = URL(filePath: ".testing/runs"),
        runID: String? = nil,
        installSignalHandler: Bool = true,
        streamOutput: @escaping @Sendable (AxolotyCommandOutputStream, String) -> Void = AxolotyCommandRunnerConfiguration.defaultStreamOutput
    ) {
        let invalidTimeout = commandTimeout.map { Self.timeoutValidationReason($0) != nil } ?? false
        let invalidGrace = !terminationGracePeriod.isFinite || terminationGracePeriod < 0
        let invalidHeartbeat = !heartbeatInterval.isFinite || heartbeatInterval <= 0
        self.commandTimeout = commandTimeout
        let safeGrace = terminationGracePeriod.isFinite ? max(0, terminationGracePeriod) : 2
        self.terminationGracePeriod = min(30, safeGrace)
        let safeHeartbeat = heartbeatInterval.isFinite ? max(0.01, heartbeatInterval) : 5
        self.heartbeatInterval = safeHeartbeat
        self.outputMode = outputMode
        if artifactRoot.isFileURL, !artifactRoot.path.hasPrefix("/") {
            self.artifactRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: artifactRoot.path)
                .standardizedFileURL
        } else {
            self.artifactRoot = artifactRoot
        }
        self.runID = runID
        self.installSignalHandler = installSignalHandler
        self.streamOutput = streamOutput
        let invalidOptions = [
            invalidTimeout ? "commandTimeout" : nil,
            invalidGrace ? "terminationGracePeriod" : nil,
            invalidHeartbeat ? "heartbeatInterval" : nil,
        ].compactMap { $0 }
        validationDiagnostic = invalidOptions.isEmpty
            ? nil
            : AxolotyCommandLifecycleDiagnostic(
                option: invalidOptions.joined(separator: ","),
                reason: "durations must be finite; commandTimeout and heartbeatInterval must be positive, "
                    + "terminationGracePeriod must be non-negative"
            )
    }

    static func timeoutValidationReason(_ timeout: TimeInterval) -> String? {
        guard timeout.isFinite else { return "must be finite" }
        guard timeout > 0 else { return "must be greater than zero" }
        // FoundationCommandExecution stores the deadline as signed nanoseconds.
        // Keep a conservative margin below Int64.max so conversion cannot trap
        // after floating-point multiplication.
        guard timeout <= 9_000_000_000 else { return "is too large" }
        return nil
    }

    /// Creates configuration from the tooling environment.
    ///
    /// `AXOLOTY_COMMAND_TIMEOUT_SECONDS`, `AXOLOTY_COMMAND_TERM_GRACE_SECONDS`,
    /// `AXOLOTY_HEARTBEAT_SECONDS`, `AXOLOTY_OUTPUT`, `AXOLOTY_RUNS_DIR`, and
    /// `AXOLOTY_RUN_ID` are recognized. An interactive stdout defaults to
    /// human output; non-interactive invocations retain the JSON-only contract.
    ///
    /// - Parameter environment: Environment values used for configuration.
    /// - Returns: Configuration with environment-derived lifecycle settings.
    public static func from(environment: [String: String]) -> Self {
        let timeout = interval(
            environment["AXOLOTY_COMMAND_TIMEOUT_SECONDS"]
                ?? environment["AXOLOTY_COMMAND_DEADLINE_SECONDS"],
            defaultValue: 30 * 60,
            allowZeroAsNil: true
        )
        let grace = interval(
            environment["AXOLOTY_COMMAND_TERM_GRACE_SECONDS"],
            defaultValue: 2,
            allowZeroAsNil: false
        ) ?? 2
        let heartbeat = interval(
            environment["AXOLOTY_HEARTBEAT_SECONDS"],
            defaultValue: 5,
            allowZeroAsNil: false
        ) ?? 5
        let outputMode: AxolotyCommandOutputMode
        switch environment["AXOLOTY_OUTPUT"] ?? environment["AXOLOTY_TOOL_OUTPUT"] {
        case "human", "progress":
            outputMode = .human
        case "json":
            outputMode = .json
        default:
            outputMode = environment["AXOLOTY_PROGRESS"] == "1" || isatty(1) == 1 ? .human : .json
        }
        let artifactPath = environment["AXOLOTY_RUNS_DIR"] ?? ".testing/runs"
        let root = URL(fileURLWithPath: artifactPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        return Self(
            commandTimeout: timeout,
            terminationGracePeriod: grace,
            heartbeatInterval: heartbeat,
            outputMode: outputMode,
            artifactRoot: root,
            runID: environment["AXOLOTY_RUN_ID"],
            installSignalHandler: environment["AXOLOTY_DISABLE_SIGNAL_HANDLING"] != "1"
        )
    }

    private static func interval(
        _ value: String?,
        defaultValue: TimeInterval,
        allowZeroAsNil: Bool
    ) -> TimeInterval? {
        guard let value else { return defaultValue }
        guard value.count <= 32,
              value.allSatisfy({ $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" || $0 == "e" || $0 == "E" })
        else { return -.infinity }
        guard !value.isEmpty, !value.hasPrefix("-"),
              let parsed = Double(value), parsed.isFinite, parsed >= 0 else { return -.infinity }
        if parsed == 0 { return allowZeroAsNil ? nil : 0 }
        return parsed
    }

    /// Writes a live output event to the corresponding process stream.
    public static func defaultStreamOutput(_ stream: AxolotyCommandOutputStream, _ text: String) {
        let handle = stream == .standardOutput ? FileHandle.standardOutput : FileHandle.standardError
        handle.write(Data(text.utf8))
    }
}

/// A structured diagnostic returned when lifecycle configuration is invalid.
public struct AxolotyCommandLifecycleDiagnostic: Codable, Equatable, Sendable {
    /// Stable diagnostic code.
    public let code: String
    /// The invalid lifecycle option.
    public let option: String
    /// Actionable validation reason.
    public let reason: String

    /// Creates a lifecycle diagnostic.
    public init(option: String, reason: String) {
        code = "invalid_lifecycle_configuration"
        self.option = option
        self.reason = reason
    }
}
