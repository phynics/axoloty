// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

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

    The initial command surface is intentionally small. Workflow commands are
    introduced only when their execution contracts and structured results exist.
    """
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
