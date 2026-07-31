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

/// Parses the stable command surface of the ``axoloty-tool`` executable.
public struct AxolotyCommandDispatcher: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let integrationRunner: any AxolotyIntegrationRunning
    private let deviceLeaseManager: any AxolotyDeviceLeasing
    private let fileSystem: any AxolotyFileSystem
    private let environment: [String: String]

    /// Creates a command dispatcher.
    public init(
        commandRunner: any AxolotyCheckCommandRunning = FoundationCommandRunner(),
        integrationRunner: (any AxolotyIntegrationRunning)? = nil,
        deviceLeaseManager: any AxolotyDeviceLeasing = FoundationDeviceLeaseManager(),
        fileSystem: (any AxolotyFileSystem)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.commandRunner = commandRunner
        self.integrationRunner = integrationRunner ?? FoundationIntegrationRunner(commandRunner: commandRunner)
        self.deviceLeaseManager = deviceLeaseManager
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
        if arguments.count == 3, arguments[0] == "wire", arguments[1] == "verify" {
            return wireBundleResult(path: arguments[2])
        }
        return switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            AxolotyCommandResult(standardOutput: Self.usage)
        case ["version"], ["--version"]:
            AxolotyCommandResult(standardOutput: "axoloty-tool \(Self.version)")
        case ["check", "--plan"]:
            Self.planResult()
        case ["check"]:
            checkResult()
        case ["build"]:
            checkResult(requested: ["build"])
        case ["test", "offline"]:
            checkResult()
        case ["test", "integration"]:
            integrationResult()
        case ["wire", "verify"]:
            checkResult(requested: ["test-wire"])
        case ["wire", "capture"]:
            execute(plan: AxolotyCheckPlan.wireCapture)
        case ["embedded", "build"]:
            checkResult(requested: ["embedded-build"])
        case ["embedded", "verify"]:
            checkResult(requested: ["embedded-linker"])
        case ["release", "snapshots"]:
            releaseSnapshotsResult()
        case ["hardware", "check"]:
            hardwareResult(required: false, device: nil)
        case ["hardware", "require"]:
            hardwareResult(required: true, device: nil)
        default:
            AxolotyCommandResult(
                standardError: "error: unsupported axoloty-tool command\n\n\(Self.usage)\n",
                exitCode: 64
            )
        }
    }

    private static let version = "0.2.0"

    private static let usage = """
    Usage: axoloty-tool <command>

    Axoloty's typed build and test orchestration CLI.

    Commands:
      help, --help, -h     Show this help.
      version, --version   Show the CLI version.
      check --plan         Print the initial offline check plan as JSON.
      check                Run the initial offline check plan and print JSON.
      build                Build the host package and its prerequisites.
      test offline         Run the same offline plan as check.
      test integration     Run transport tests against local Mosquitto.
      wire verify [BUNDLE] Verify fixtures and an optional bundle without MQTT.
      wire capture         Run live MQTT captures with pinned reference agents.
      embedded build       Cross-compile the ESP32-C6 firmware on Linux.
      embedded verify      Build and verify the ESP32-C6 linker contract.
      hardware check       Run or skip the sporadic hardware smoke check.
      hardware require     Require an attached device and run its smoke check.
      release snapshots    Generate and verify a provenance-rich wire bundle.
        --device PATH      Override AXOLOTY_DEVICE (default: /dev/ttyACM0).

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

    private func checkResult(requested: [String]? = nil) -> AxolotyCommandResult {
        do {
            let availablePlan = AxolotyCheckPlan.initialOffline
            guard requested?.allSatisfy({ requestedName in
                availablePlan.nodes.contains { $0.name == requestedName }
            }) != false else {
                return AxolotyCommandResult(
                    standardError: "error: requested check is unavailable on this platform\n",
                    exitCode: 69
                )
            }
            let plan = try AxolotyCheckPlanner().plan(availablePlan.nodes, requested: requested)
            let results = AxolotyCheckExecutor(commandRunner: commandRunner).execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return try Self.jsonResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to plan checks\n", exitCode: 70)
        }
    }

    private func releaseSnapshotsResult() -> AxolotyCommandResult {
        do {
            let source = environment["AXOLOTY_SNAPSHOT_SOURCE"] ?? "Tests/WireCompatibility/Fixtures"
            let destination = environment["AXOLOTY_SNAPSHOT_OUTPUT"] ?? ".testing/release-snapshots"
            let forwardedEnvironment = ["AXOLOTY_IMAGE_IDENTITY", "AXOLOTY_GIT_COMMIT", "AXOLOTY_GIT_CLEAN"]
                .reduce(into: [String: String]()) { values, name in
                    values[name] = environment[name]
                }
            let plan = try AxolotyCheckPlanner().plan(
                AxolotyCheckPlan.releaseSnapshots(
                    source: source,
                    destination: destination,
                    environment: forwardedEnvironment
                ).nodes
            )
            let results = AxolotyCheckExecutor(commandRunner: commandRunner).execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return try Self.jsonResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(
                standardError: "error: unable to generate release snapshots\n",
                exitCode: 70
            )
        }
    }

    private func wireBundleResult(path: String) -> AxolotyCommandResult {
        do {
            let bundleNode = AxolotyCheckNode(
                name: "wire-bundle-verify",
                dependencies: ["test-wire"],
                command: AxolotyCommandPlan(
                    executable: "node",
                    arguments: ["Tests/Support/release-snapshots.mjs", "verify", path]
                )
            )
            let plan = try AxolotyCheckPlanner().plan(
                AxolotyCheckPlan.initialOffline.nodes + [bundleNode],
                requested: [bundleNode.name]
            )
            let results = AxolotyCheckExecutor(commandRunner: commandRunner).execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return try Self.jsonResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
        } catch {
            return AxolotyCommandResult(standardError: "error: unable to verify wire bundle\n", exitCode: 70)
        }
    }

    private func integrationResult() -> AxolotyCommandResult {
        if environment["AXOLOTY_TOOL_HOST"] == "1" {
            let result = commandRunner.run(AxolotyCommandPlan(
                executable: "/opt/axoloty/bin/axoloty-tool",
                arguments: ["test", "integration"],
                environment: ["AXOLOTY_IN_CONTAINER": "1"]
            ))
            return AxolotyCommandResult(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                exitCode: result.exitCode
            )
        }
        let command = integrationRunner.run()
        let result = AxolotyCheckResult(
            name: "integration-tests",
            status: command.exitCode == 0 ? .passed : .failed,
            command: command
        )
        return (try? Self.jsonResult(
            AxolotyCheckManifest(results: [result]),
            exitCode: command.exitCode == 0 ? 0 : 1
        )) ?? AxolotyCommandResult(exitCode: 70)
    }

    private func execute(plan availablePlan: AxolotyCheckPlan) -> AxolotyCommandResult {
        do {
            let plan = try AxolotyCheckPlanner().plan(availablePlan.nodes)
            let results = AxolotyCheckExecutor(commandRunner: commandRunner).execute(plan)
            let exitCode: Int32 = results.allSatisfy { $0.status == .passed } ? 0 : 1
            return try Self.jsonResult(AxolotyCheckManifest(results: results), exitCode: exitCode)
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
        guard let lease = deviceLeaseManager.acquire(device: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device lease is unavailable"
            )
            return (try? Self.jsonResult(outcome, exitCode: required ? 1 : 0)) ?? AxolotyCommandResult(exitCode: 70)
        }
        let command = AxolotyCommandPlan(
            executable: "Tests/Support/embedded-swift-smoke.sh",
            environment: ["EMBEDDED_DEVICE": selectedDevice]
        )
        let result = commandRunner.run(command)
        withExtendedLifetime(lease) {}
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
