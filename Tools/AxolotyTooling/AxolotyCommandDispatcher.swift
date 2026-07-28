// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses the stable command surface of the ``ax`` tooling executable.
public struct AxolotyCommandDispatcher: Sendable {
    /// Creates a command dispatcher.
    public init() {}

    /// Resolves command-line arguments to their externally visible result.
    ///
    /// - Parameter arguments: Arguments after the executable name.
    /// - Returns: Text streams and exit status for the requested command.
    public func run(arguments: [String]) -> AxolotyCommandResult {
        switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            AxolotyCommandResult(standardOutput: Self.usage)
        case ["version"], ["--version"]:
            AxolotyCommandResult(standardOutput: "ax \(Self.version)")
        case ["check", "--plan"]:
            Self.planResult()
        case ["check"]:
            Self.checkResult()
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
