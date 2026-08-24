// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import AxolotyProcessLauncher

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// swiftlint:disable file_length function_parameter_count optional_data_string_conversion
/// Selects how output from a managed command is exposed while it runs.
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

/// A cancellation token owned by a command-runner invocation.
public final class AxolotyCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Creates a cancellation token.
    public init() {}

    /// Requests cancellation of the currently running command.
    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    /// Whether cancellation has been requested.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @discardableResult
    func observe(_ callback: @escaping @Sendable () -> Void) -> AxolotyCancellationObservation {
        let id = UUID()
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled {
            observers[id] = callback
        }
        lock.unlock()
        if alreadyCancelled {
            callback()
        }
        return AxolotyCancellationObservation { [weak self] in
            self?.removeObserver(id)
        }
    }

    private func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}

final class AxolotyCancellationObservation: @unchecked Sendable {
    private let release: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    func cancel() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        release()
    }

    deinit { cancel() }
}

/// Configuration for ``FoundationCommandRunner`` lifecycle behavior.
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

final class AxolotyCommandArtifactStore: @unchecked Sendable {
    struct Artifact {
        let directory: URL
        let metadata: URL
        let manifest: URL
        let verifierLog: URL
        let standardOutput: URL
        let standardError: URL
        let result: URL
        let secretArgumentValues: [String]
    }

    private let root: URL
    let runID: String
    private let environmentKeys: [String]
    private let environmentValues: [String]
    private let environment: [String: String]
    private let lock = NSLock()
    private var nextIndex = 0
    private var wroteRunMetadata = false

    init(
        root: URL,
        runID: String?,
        environment: [String: String]
    ) {
        self.root = root
        self.runID = runID ?? UUID().uuidString
        self.environment = environment
        self.environmentKeys = environment.keys.sorted()
        self.environmentValues = Self.secretValues(in: environment)
    }

    func begin(
        command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext,
        startedAt: Date,
        deadline: Date?
    ) throws -> Artifact {
        guard Self.isSafeIdentifier(runID) else {
            throw ArtifactStoreError.unsafeRoot("run ID must contain only letters, numbers, '.', '_' or '-' and must not be '.' or '..'")
        }
        try validateRoot()
        try validateContainedPath(root.appending(path: runID, directoryHint: .isDirectory))
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        let shouldWriteRunMetadata = !wroteRunMetadata
        wroteRunMetadata = true
        lock.unlock()

        let runDirectory = root.appending(path: runID, directoryHint: .isDirectory)
        try createDirectorySafely(at: runDirectory)
        if shouldWriteRunMetadata {
            let runMetadata: [String: Any] = [
                "artifactContract": [
                    "manifest.json", "verifier.log", "metadata.json", "stdout.txt", "stderr.txt", "result.json",
                ],
                "environmentKeys": environmentKeys,
                "runId": runID,
                "startedAt": ISO8601DateFormatter().string(from: startedAt),
            ]
            try writeJSON(runMetadata, to: runDirectory.appending(path: "run.json"))
        }

        let node = Self.sanitize(context.node ?? "command")
        let directory = runDirectory.appending(path: String(format: "%03d-%@", index + 1, node), directoryHint: .isDirectory)
        try createDirectorySafely(at: directory)
        try validateContainedPath(directory)
        let commandEnvironment = environment.merging(command.environment) { _, value in value }
        let commandEnvironmentKeys = commandEnvironment.keys.sorted()
        let artifact = Artifact(
            directory: directory,
            metadata: directory.appending(path: "metadata.json"),
            manifest: directory.appending(path: "manifest.json"),
            verifierLog: directory.appending(path: "verifier.log"),
            standardOutput: directory.appending(path: "stdout.txt"),
            standardError: directory.appending(path: "stderr.txt"),
            result: directory.appending(path: "result.json"),
            secretArgumentValues: secretArgumentValues(in: command.arguments)
        )
        let metadata: [String: Any] = [
            "argumentCount": command.arguments.count,
            "arguments": redactArguments(command.arguments, environment: commandEnvironment),
            "argv": redactArguments([command.executable] + command.arguments, environment: commandEnvironment),
            "context": command.executionContext.rawValue,
            "deadline": deadline.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "environmentKeys": commandEnvironmentKeys,
            "executable": command.executable,
            "node": context.node ?? NSNull(),
            "stage": context.stage,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        try writeJSON(metadata, to: artifact.metadata)
        try writeJSON([
            "artifactFiles": [
                "manifest.json", "verifier.log", "metadata.json", "stdout.txt", "stderr.txt", "result.json",
            ],
            "deadline": deadline.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "node": context.node ?? NSNull(),
            "runId": runID,
            "stage": context.stage,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "status": "running",
        ], to: artifact.manifest)
        try Data([
            "[axoloty] phase=started run-id=\(runID) node=\(context.node ?? "command") stage=\(context.stage)\n",
        ].joined().utf8).write(to: artifact.verifierLog, options: .atomic)
        return artifact
    }

    func finish(
        _ artifact: Artifact,
        startedAt: Date,
        finishedAt: Date,
        result: AxolotyCheckCommandResult,
        standardOutput: Data,
        standardError: Data,
        progress: Data = Data(),
        additionalEnvironment: [String: String] = [:]
    ) {
        let output = redacted(standardOutput, artifact: artifact, additionalEnvironment: additionalEnvironment)
        let error = redacted(standardError, artifact: artifact, additionalEnvironment: additionalEnvironment)
        try? output.write(to: artifact.standardOutput, options: .atomic)
        try? error.write(to: artifact.standardError, options: .atomic)

        let outputText = String(decoding: output, as: UTF8.self)
        let errorText = String(decoding: error, as: UTF8.self)
        let progressText = String(
            decoding: redacted(progress, artifact: artifact, additionalEnvironment: additionalEnvironment),
            as: UTF8.self
        )
        let verifierText = "[progress]\n"
            + progressText
            + (progressText.hasSuffix("\n") ? "" : "\n")
            + "[stdout]\n"
            + outputText
            + (outputText.hasSuffix("\n") ? "" : "\n")
            + "[stderr]\n"
            + errorText
            + (errorText.hasSuffix("\n") ? "" : "\n")
        let verifier = Data(verifierText.utf8)
        try? verifier.write(to: artifact.verifierLog, options: .atomic)

        var metadata: [String: Any] = [
            "elapsedSeconds": finishedAt.timeIntervalSince(startedAt),
            "endedAt": ISO8601DateFormatter().string(from: finishedAt),
            "exitCode": result.exitCode,
            "outcome": result.lifecycle?.outcome.rawValue ?? (result.exitCode == 0 ? "passed" : "failed"),
        ]
        if let lifecycle = result.lifecycle {
            metadata["artifactPath"] = lifecycle.artifactPath ?? NSNull()
            metadata["deadline"] = lifecycle.deadline ?? NSNull()
            metadata["lastTest"] = lifecycle.lastTest ?? NSNull()
            metadata["node"] = lifecycle.node ?? NSNull()
            metadata["stage"] = lifecycle.stage
            metadata["escalatedToKill"] = lifecycle.escalatedToKill
        }
        try? writeJSON(metadata, to: artifact.metadata, mergeWithExisting: true)

        var manifest: [String: Any] = [
            "endedAt": ISO8601DateFormatter().string(from: finishedAt),
            "elapsedSeconds": finishedAt.timeIntervalSince(startedAt),
            "exitCode": result.exitCode,
            "status": result.exitCode == 0 ? "passed" : "failed",
        ]
        if let lifecycle = result.lifecycle {
            manifest["outcome"] = lifecycle.outcome.rawValue
            manifest["lastTest"] = lifecycle.lastTest ?? NSNull()
            manifest["escalatedToKill"] = lifecycle.escalatedToKill
        } else {
            manifest["outcome"] = result.exitCode == 0 ? "passed" : "failed"
        }
        try? writeJSON(manifest, to: artifact.manifest, mergeWithExisting: true)

        let durableResult: [String: Any] = [
            "artifactPath": artifact.directory.path,
            "elapsedSeconds": finishedAt.timeIntervalSince(startedAt),
            "exitCode": result.exitCode,
            "outcome": result.lifecycle?.outcome.rawValue ?? (result.exitCode == 0 ? "passed" : "failed"),
            "timedOut": result.lifecycle?.outcome == .timedOut,
            "lastTest": result.lifecycle?.lastTest ?? NSNull(),
            "escalatedToKill": result.lifecycle?.escalatedToKill ?? false,
        ]
        try? writeJSON(durableResult, to: artifact.result)
    }

    private func redacted(
        _ data: Data,
        artifact: Artifact,
        additionalEnvironment: [String: String]
    ) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let values = (environmentValues + Self.secretValues(in: additionalEnvironment) + artifact.secretArgumentValues)
            .sorted { $0.count > $1.count }
        var result = text
        for value in values where !value.isEmpty {
            result = result.replacingOccurrences(of: value, with: "<redacted>")
        }
        return Data(result.utf8)
    }

    private func redactArguments(_ arguments: [String], environment: [String: String]) -> [String] {
        let values = Self.secretValues(in: environment).sorted { $0.count > $1.count }
        var expectsSecret = false
        return arguments.map { argument in
            if expectsSecret {
                expectsSecret = false
                return "<redacted>"
            }
            if isSecretOption(argument) {
                if let separator = argument.firstIndex(of: "=") {
                    return String(argument[..<separator]) + "=<redacted>"
                }
                expectsSecret = true
                return argument
            }
            var redacted = argument
            for value in values {
                redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
            }
            return redacted
        }
    }

    private func secretArgumentValues(in arguments: [String]) -> [String] {
        var values: [String] = []
        var expectsSecret = false
        for argument in arguments {
            if expectsSecret {
                if !argument.isEmpty { values.append(argument) }
                expectsSecret = false
                continue
            }
            guard isSecretOption(argument) else { continue }
            if let separator = argument.firstIndex(of: "=") {
                let value = String(argument[argument.index(after: separator)...])
                if !value.isEmpty { values.append(value) }
            } else {
                expectsSecret = true
            }
        }
        return values
    }

    private func isSecretOption(_ argument: String) -> Bool {
        let key = argument.split(separator: "=", maxSplits: 1).first?.lowercased() ?? ""
        return Self.secretKey(key)
    }

    private static func secretKey(_ key: String) -> Bool {
        ["password", "pass", "token", "secret", "key", "auth", "credential", "cookie", "private", "ssid"]
            .contains { key.lowercased().contains($0) }
    }

    private static func secretValues(in environment: [String: String]) -> [String] {
        environment.compactMap { key, value in
            guard !value.isEmpty, secretKey(key) else { return nil }
            return value
        }
    }

    private func validateRoot() throws {
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw ArtifactStoreError.unsafeRoot("artifact root must be an absolute file path")
        }
        var current = URL(fileURLWithPath: "/")
        for component in root.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard FileManager.default.fileExists(atPath: current.path) else { break }
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ArtifactStoreError.unsafeRoot("artifact root contains a symbolic link")
            }
        }
        if FileManager.default.fileExists(atPath: root.path) {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ArtifactStoreError.unsafeRoot("artifact root is not a directory")
            }
        }
    }

    private func createDirectorySafely(at url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: current.path) {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                    throw ArtifactStoreError.unsafeRoot("artifact path contains a symbolic link")
                }
                var isDirectory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ArtifactStoreError.unsafeRoot("artifact path component is not a directory")
                }
            } else {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        }
    }

    private func validateContainedPath(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ArtifactStoreError.unsafeRoot("artifact path contains a symbolic link")
            }
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedURL == resolvedRoot || resolvedURL.hasPrefix(resolvedRoot + "/") else {
            throw ArtifactStoreError.unsafeRoot("artifact path escapes artifact root")
        }
    }

    private enum ArtifactStoreError: LocalizedError {
        case unsafeRoot(String)

        var errorDescription: String? {
            switch self {
            case .unsafeRoot(let reason): return reason
            }
        }
    }

    private func writeJSON(
        _ value: [String: Any],
        to url: URL,
        mergeWithExisting: Bool = false
    ) throws {
        var object = value
        if mergeWithExisting,
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing.merging(value) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func sanitize(_ value: String) -> String {
        let sanitized = value.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character
                : "-"
        }
        return String(sanitized.prefix(80)).isEmpty ? "run" : String(sanitized.prefix(80))
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.count <= 80
            && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}

final class AxolotyCommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output: [AxolotyCommandOutputStream: Data] = [:]
    private var progress = Data()
    private var pendingLines: [AxolotyCommandOutputStream: String] = [:]
    private var latestStartedTest: String?
    private let streamOutput: @Sendable (AxolotyCommandOutputStream, String) -> Void
    private let streamedStreams: Set<AxolotyCommandOutputStream>
    private let streamLock = NSLock()

    init(
        streamOutput: @escaping @Sendable (AxolotyCommandOutputStream, String) -> Void,
        streamedStreams: Set<AxolotyCommandOutputStream>
    ) {
        self.streamOutput = streamOutput
        self.streamedStreams = streamedStreams
    }

    func append(_ data: Data, from stream: AxolotyCommandOutputStream) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        streamLock.lock()
        lock.lock()
        output[stream, default: Data()].append(data)
        let previous = pendingLines[stream, default: ""]
        let combined = previous + text
        let components = combined.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLines[stream] = components.last.map(String.init) ?? ""
        for line in components.dropLast() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
        }
        let shouldStream = streamedStreams.contains(stream)
        lock.unlock()

        if shouldStream {
            streamOutput(stream, text)
        }
        streamLock.unlock()
    }

    func emitProgress(_ text: String) {
        streamLock.lock()
        lock.lock()
        progress.append(Data(text.utf8))
        lock.unlock()
        streamOutput(.standardError, text)
        streamLock.unlock()
    }

    func data(for stream: AxolotyCommandOutputStream) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return output[stream, default: Data()]
    }

    var latestTest: String? {
        lock.lock()
        defer { lock.unlock() }
        return latestStartedTest
    }

    func diagnosticSnapshot() -> (lastTest: String?, outputBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let outputBytes = output.values.reduce(into: 0) { total, data in total += data.count }
        return (latestStartedTest, outputBytes)
    }

    func progressData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func finishLines() {
        lock.lock()
        defer { lock.unlock() }
        for line in pendingLines.values {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains("◇ Test "), candidate.contains(" started") {
                latestStartedTest = candidate
            }
        }
        pendingLines.removeAll()
    }
}

final class AxolotySignalLease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    private var released = false
    private let lock = NSLock()

    init(release: @escaping @Sendable () -> Void) { self.release = release }

    func cancel() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        release()
    }

    deinit { cancel() }
}

final class AxolotySignalMultiplexer: @unchecked Sendable {
    static let shared = AxolotySignalMultiplexer()
    private let lock = NSLock()
    private var callbacks: [UUID: @Sendable () -> Void] = [:]
    private var handler: ServiceSignalHandler?
    private var savedSignalDispositions: (int: UnsafeMutableRawPointer?, term: UnsafeMutableRawPointer?)?

    func acquire(callback: @escaping @Sendable () -> Void) -> AxolotySignalLease {
        let id = UUID()
        lock.lock()
        callbacks[id] = callback
        if handler == nil {
            savedSignalDispositions = (
                axoloty_capture_signal_disposition(SIGINT),
                axoloty_capture_signal_disposition(SIGTERM)
            )
            let signalHandler = ServiceSignalHandler(onInterrupt: { [weak self] in self?.notify() })
            signalHandler.install()
            handler = signalHandler
        }
        lock.unlock()
        return AxolotySignalLease { [weak self] in self?.release(id: id) }
    }

    private func notify() {
        lock.lock()
        let currentCallbacks = Array(callbacks.values)
        lock.unlock()
        currentCallbacks.forEach { $0() }
    }

    #if DEBUG
    func notifyForTesting() {
        notify()
    }
    #endif

    private func release(id: UUID) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        if callbacks.isEmpty, let handler {
            self.handler = nil
            handler.uninstall()
            if let savedSignalDispositions {
                _ = axoloty_restore_signal_disposition(SIGINT, savedSignalDispositions.int)
                _ = axoloty_restore_signal_disposition(SIGTERM, savedSignalDispositions.term)
                axoloty_release_signal_disposition(savedSignalDispositions.int)
                axoloty_release_signal_disposition(savedSignalDispositions.term)
                self.savedSignalDispositions = nil
            }
        }
        lock.unlock()
    }
}
