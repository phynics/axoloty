// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A Foundation-backed runner for the repository's local tooling commands.
protocol AxolotyArtifactInvocationIdentifying: Sendable {
    var artifactInvocation: AxolotyArtifactInvocation { get }
}

struct AxolotyArtifactInvocation: Sendable {
    let runID: String
    let invocationID: String
    let parentInvocationID: String?
    let reportDirectory: URL
}

public struct FoundationCommandRunner: AxolotyLifecycleCommandRunning, AxolotyArtifactInvocationIdentifying {
    private let contextValidator: AxolotyExecutionContextValidator
    private let environment: [String: String]
    private let configuration: AxolotyCommandRunnerConfiguration
    private let cancellation: AxolotyCommandCancellation
    private let artifactStore: AxolotyCommandArtifactStore

    var artifactInvocation: AxolotyArtifactInvocation {
        AxolotyArtifactInvocation(
            runID: artifactStore.runID,
            invocationID: artifactStore.invocationID,
            parentInvocationID: artifactStore.parentInvocationID,
            reportDirectory: artifactStore.reportDirectory
        )
    }

    /// Creates a Foundation-backed command runner.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        self.init(
            contextValidator: AxolotyExecutionContextValidator(environment: environment),
            environment: environment,
            configuration: .from(environment: environment),
            cancellation: AxolotyCommandCancellation()
        )
    }

    init(contextValidator: AxolotyExecutionContextValidator) {
        let environment = ProcessInfo.processInfo.environment
            .merging(contextValidator.environment) { _, injected in injected }
        self.init(
            contextValidator: contextValidator,
            environment: environment,
            configuration: .from(environment: environment),
            cancellation: AxolotyCommandCancellation()
        )
    }

    init(
        contextValidator: AxolotyExecutionContextValidator,
        environment: [String: String],
        configuration: AxolotyCommandRunnerConfiguration? = nil,
        cancellation: AxolotyCommandCancellation = AxolotyCommandCancellation()
    ) {
        self.contextValidator = contextValidator
        self.environment = environment
        self.configuration = configuration ?? .from(environment: environment)
        self.cancellation = cancellation
        artifactStore = AxolotyCommandArtifactStore(
            root: (configuration ?? .from(environment: environment)).artifactRoot,
            runID: (configuration ?? .from(environment: environment)).runID,
            environment: environment
        )
    }

    /// Requests cancellation of the currently running command.
    public func cancel() {
        cancellation.cancel()
    }

    /// Runs a command through the current process environment.
    ///
    /// - Parameter command: The command to execute.
    /// - Returns: Its exit status and captured output.
    public func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        run(command, context: AxolotyCommandRunContext())
    }

    /// Runs a command with node-aware lifecycle diagnostics.
    ///
    /// - Parameters:
    ///   - command: The command to execute.
    ///   - context: The node and stage owning the command.
    /// - Returns: Its exit status, captured output, and lifecycle diagnostics.
    public func run(
        _ command: AxolotyCommandPlan,
        context: AxolotyCommandRunContext
    ) -> AxolotyCheckCommandResult {
        if let diagnostic = contextValidator.validate(command) {
            return AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: contextValidator.diagnosticMessage(diagnostic)
            )
        }
        if let validationError = configuration.validationDiagnostic {
            return AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: (try? JSONEncoder().encode(validationError)).map { String(decoding: $0, as: UTF8.self) } ?? "invalid lifecycle configuration"
            )
        }
        if let timeout = command.timeoutSeconds,
           let reason = AxolotyCommandRunnerConfiguration.timeoutValidationReason(timeout) {
            let diagnostic = AxolotyCommandLifecycleDiagnostic(
                option: "commandTimeout",
                reason: reason
            )
            return AxolotyCheckCommandResult(
                exitCode: 64,
                standardError: (try? JSONEncoder().encode(diagnostic)).map { String(decoding: $0, as: UTF8.self) } ?? "invalid lifecycle configuration"
            )
        }
        do {
            return try FoundationCommandExecution(
                environment: environment,
                configuration: configuration,
                cancellation: cancellation,
                artifactStore: artifactStore
            ).run(command, context: context)
        } catch {
            return AxolotyCheckCommandResult(
                exitCode: 70,
                standardError: "unable to start command \(command.executable): \(error.localizedDescription)"
            )
        }
    }
}
