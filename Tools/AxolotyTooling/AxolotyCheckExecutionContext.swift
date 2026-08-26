// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

struct AxolotyExecutionContextDiagnostic: Codable, Equatable, Sendable {
    let code: String
    let executable: String
    let declaredContext: AxolotyCommandPlan.ExecutionContext
    let detectedContext: AxolotyCommandPlan.ExecutionContext
    let message: String
    let remediation: String

    init(
        executable: String,
        declaredContext: AxolotyCommandPlan.ExecutionContext,
        detectedContext: AxolotyCommandPlan.ExecutionContext
    ) {
        self.code = "execution_context_mismatch"
        self.executable = executable
        self.declaredContext = declaredContext
        self.detectedContext = detectedContext
        self.message = "Command requires the \(declaredContext.rawValue) execution context, "
            + "but the current tooling process is in the \(detectedContext.rawValue) context."
        self.remediation = declaredContext == .project
            ? "Run this command through the pinned project container."
            : "Run this command directly on the host or configure the project container's "
                + "executable host-runtime wrapper and Unix socket. This prevents accidental "
                + "wrong-context execution; it does not defend against adversarial environment "
                + "or filesystem spoofing."
    }
}

struct AxolotyExecutionContextValidator: Sendable {
    let environment: [String: String]
    private let platform: AxolotyCheckPlan.Platform

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platform: AxolotyCheckPlan.Platform = AxolotyCheckPlan.currentPlatform
    ) {
        self.environment = environment
        self.platform = platform
    }

    var detectedContext: AxolotyCommandPlan.ExecutionContext {
        if environment["AXOLOTY_DEVCONTAINER"] == "1" || platform == .macOS {
            return .project
        }
        return .host
    }

    private var hasHostRuntimeBridge: Bool {
        guard environment["AXOLOTY_DEVCONTAINER"] == "1",
              environment["AXOLOTY_HOST_RUNTIME_BRIDGE"] == "1",
              let runtime = environment["CONTAINER_RUNTIME"],
              FileManager.default.isExecutableFile(atPath: runtime),
              let dockerHost = environment["DOCKER_HOST"],
              dockerHost.hasPrefix("unix://")
        else { return false }

        let socketPath = String(dockerHost.dropFirst("unix://".count))
        guard socketPath.hasPrefix("/") else { return false }
        let resolvedSocketPath = URL(filePath: socketPath).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedSocketPath)
        return (attributes?[.type] as? FileAttributeType) == .typeSocket
    }

    func validate(_ command: AxolotyCommandPlan) -> AxolotyExecutionContextDiagnostic? {
        let usesBridgedHostContext = command.executionContext == .host && hasHostRuntimeBridge
        guard command.executionContext != detectedContext && !usesBridgedHostContext else { return nil }
        return AxolotyExecutionContextDiagnostic(
            executable: command.executable,
            declaredContext: command.executionContext,
            detectedContext: detectedContext
        )
    }

    func failureResult(validating commands: [AxolotyCommandPlan]) -> AxolotyCheckCommandResult? {
        guard let diagnostic = commands.lazy.compactMap(validate).first else { return nil }
        return AxolotyCheckCommandResult(
            exitCode: 64,
            standardError: diagnosticMessage(diagnostic)
        )
    }

    func diagnosticMessage(_ diagnostic: AxolotyExecutionContextDiagnostic) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(diagnostic)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
