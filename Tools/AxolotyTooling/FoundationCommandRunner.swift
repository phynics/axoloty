// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Foundation-backed runner for the repository's local tooling commands.
public struct FoundationCommandRunner: AxolotyCheckCommandRunning {
    private let environment: [String: String]

    /// Creates a Foundation-backed command runner.
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Runs a command through the current process environment.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: Its exit status and captured output.
    public func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        do {
            return try execute(hostWrapped(command))
        } catch {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start command \(command.executable): \(error.localizedDescription)"
            )
        }
    }

    private func hostWrapped(_ command: AxolotyCommandPlan) -> AxolotyCommandPlan {
        guard environment["AXOLOTY_TOOL_HOST"] == "1", command.executionContext == .project else {
            return command
        }
        var forwarded = command.environment
        if !command.environment.isEmpty {
            forwarded["CONTAINER_ENV_VARS"] = command.environment.keys.sorted().joined(separator: " ")
        }
        if let device = command.environment["EMBEDDED_DEVICE"] {
            forwarded["CONTAINER_OPTIONAL_DEVICES"] = device
        }
        return AxolotyCommandPlan(
            executable: ".devcontainer/run.sh",
            arguments: [command.executable] + command.arguments,
            environment: forwarded,
            executionContext: .host
        )
    }

    private func execute(_ command: AxolotyCommandPlan) throws -> AxolotyCheckCommandResult {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appending(path: "axoloty-tool-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let standardOutputURL = artifactDirectory.appending(path: "stdout.txt")
        let standardErrorURL = artifactDirectory.appending(path: "stderr.txt")
        _ = FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command.executable] + command.arguments
        if !command.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, value in value }
        }
        process.standardOutput = try FileHandle(forWritingTo: standardOutputURL)
        process.standardError = try FileHandle(forWritingTo: standardErrorURL)

        try process.run()
        process.waitUntilExit()

        return AxolotyCheckCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: standardOutputURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: standardErrorURL), as: UTF8.self)
        )
    }
}
