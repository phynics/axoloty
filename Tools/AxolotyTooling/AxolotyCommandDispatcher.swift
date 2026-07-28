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
}

private struct FoundationFileSystem: AxolotyFileSystem {
    init() {}
    func exists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
}

/// Parses the stable command surface of the ``ax`` tooling executable.
public struct AxolotyCommandDispatcher: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let fileSystem: any AxolotyFileSystem
    private let environment: [String: String]

    /// Creates a command dispatcher.
    public init(
        commandRunner: any AxolotyCheckCommandRunning = FoundationCommandRunner(),
        fileSystem: (any AxolotyFileSystem)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem ?? FoundationFileSystem()
        self.environment = environment
    }

    /// Resolves command-line arguments to their externally visible result.
    ///
    /// - Parameter arguments: Arguments after the executable name.
    /// - Returns: Text streams and exit status for the requested command.
    public func run(arguments: [String]) -> AxolotyCommandResult {
        if arguments.count == 4, arguments[0] == "hardware", ["check", "require"].contains(arguments[1]), arguments[2] == "--device" {
            return hardwareResult(required: arguments[1] == "require", device: arguments[3])
        }
        return switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            AxolotyCommandResult(standardOutput: Self.usage)
        case ["version"], ["--version"]:
            AxolotyCommandResult(standardOutput: "ax \(Self.version)")
        case ["check", "--plan"]:
            Self.planResult()
        case ["check"]:
            Self.checkResult()
        case ["hardware", "check"]:
            hardwareResult(required: false, device: nil)
        case ["hardware", "require"]:
            hardwareResult(required: true, device: nil)
        default:
            AxolotyCommandResult(
                standardError: "error: unsupported ax command\n\n\(Self.usage)\n",
                exitCode: 64
            )
        }
    }

    private static let version = "0.1.0"

    private static let usage = """
    Usage: ax <command>

    Axoloty's typed build and test orchestration CLI.

    Commands:
      help, --help, -h     Show this help.
      version, --version   Show the CLI version.
      check --plan         Print the initial offline check plan as JSON.
      check                Run the initial offline check plan and print JSON.
      hardware check      Run the optional embedded hardware smoke check.
      hardware require    Require and run the embedded hardware smoke check.
        --device PATH     Override AXOLOTY_DEVICE (default: /dev/ttyACM0).

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """

    private static func planResult() -> AxolotyCommandResult {
        do {
            let plan = try AxolotyCheckPlanner().plan(AxolotyCheckPlan.initialOffline.nodes)
            return try jsonResult(plan)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to plan checks\n", exitCode: 70)
        }
    }

    private static func checkResult() -> AxolotyCommandResult {
        do {
            let plan = try AxolotyCheckPlanner().plan(AxolotyCheckPlan.initialOffline.nodes)
            let results = AxolotyCheckExecutor(commandRunner: FoundationCommandRunner()).execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return try jsonResult(results, exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to plan checks\n", exitCode: 70)
        }
    }

    private func hardwareResult(required: Bool, device: String?) -> AxolotyCommandResult {
        let selectedDevice = device ?? environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
        guard fileSystem.exists(atPath: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device is not present"
            )
            return (try? Self.jsonResult(outcome, exitCode: required ? 1 : 0)) ?? AxolotyCommandResult(exitCode: 70)
        }
        let command = AxolotyCommandPlan(
            executable: "Tests/Support/embedded-swift-smoke.sh",
            environment: ["EMBEDDED_DEVICE": selectedDevice]
        )
        let result = commandRunner.run(command)
        let outcome = AxolotyHardwareOutcome(
            status: result.exitCode == 0 ? .passed : .failed,
            device: selectedDevice,
            reason: result.exitCode == 0
                ? "hardware smoke test passed"
                : (result.standardError.isEmpty
                    ? "hardware smoke test failed"
                    : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return (try? Self.jsonResult(outcome, exitCode: result.exitCode == 0 ? 0 : 1)) ?? AxolotyCommandResult(exitCode: 70)
    }

    private static func jsonResult<Value: Encodable>(
        _ value: Value,
        exitCode: Int32 = 0
    ) throws -> AxolotyCommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return AxolotyCommandResult(
            standardOutput: String(decoding: data, as: UTF8.self),
            exitCode: exitCode
        )
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
