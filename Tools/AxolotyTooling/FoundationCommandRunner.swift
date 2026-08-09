// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Foundation-backed runner for the repository's local tooling commands.
public struct FoundationCommandRunner: AxolotyCheckCommandRunning {
    private let contextValidator: AxolotyExecutionContextValidator
    private let environment: [String: String]

    /// Creates a Foundation-backed command runner.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        contextValidator = AxolotyExecutionContextValidator(environment: environment)
        self.environment = environment
    }

    init(contextValidator: AxolotyExecutionContextValidator) {
        self.contextValidator = contextValidator
        environment = ProcessInfo.processInfo.environment
            .merging(contextValidator.environment) { _, injected in injected }
    }

    /// Runs a command through the current process environment.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: Its exit status and captured output.
    public func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        if let diagnostic = contextValidator.validate(command) {
            return AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: contextValidator.diagnosticMessage(diagnostic)
            )
        }
        do {
            return try execute(command)
        } catch {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start command \(command.executable): \(error.localizedDescription)"
            )
        }
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
        process.environment = environment.merging(command.environment) { _, value in value }
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
