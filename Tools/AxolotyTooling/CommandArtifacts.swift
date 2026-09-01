// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

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
    let invocationID: String
    private let parentInvocationID: String?
    private let environmentKeys: [String]
    private let environmentValues: [String]
    private let environment: [String: String]
    private let lock = NSLock()
    private var nextIndex = 0
    private var preparedInvocation = false

    init(
        root: URL,
        runID: String?,
        environment: [String: String]
    ) {
        self.root = root
        self.runID = runID ?? UUID().uuidString
        invocationID = UUID().uuidString.lowercased()
        parentInvocationID = environment["AXOLOTY_PARENT_INVOCATION_ID"]
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
        let runDirectory = root.appending(path: runID, directoryHint: .isDirectory)
        try validateContainedPath(runDirectory)
        lock.lock()
        defer { lock.unlock() }
        if !preparedInvocation {
            try prepareInvocation(startedAt: startedAt, runDirectory: runDirectory)
            preparedInvocation = true
        }
        let index = nextIndex
        nextIndex += 1

        let node = Self.sanitize(context.node ?? "command")
        let directory = invocationDirectory(runDirectory: runDirectory)
            .appending(path: "commands", directoryHint: .isDirectory)
            .appending(path: String(format: "%03d-%@", index + 1, node), directoryHint: .isDirectory)
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
            "invocationId": invocationID,
            "runId": runID,
            "stage": context.stage,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "status": "running",
        ], to: artifact.manifest)
        try Data([
            "[axoloty] phase=started run-id=\(runID) invocation-id=\(invocationID) node=\(context.node ?? "command") stage=\(context.stage)\n",
        ].joined().utf8).write(to: artifact.verifierLog, options: .atomic)
        return artifact
    }

    private func prepareInvocation(startedAt: Date, runDirectory: URL) throws {
        let invocationsDirectory = runDirectory.appending(path: "invocations", directoryHint: .isDirectory)
        try createDirectorySafely(at: invocationsDirectory)
        let invocationDirectory = invocationDirectory(runDirectory: runDirectory)
        try validateContainedPath(invocationDirectory)
        guard !FileManager.default.fileExists(atPath: invocationDirectory.path) else {
            throw ArtifactStoreError.unsafeRoot("artifact invocation already exists")
        }
        try FileManager.default.createDirectory(
            at: invocationDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let commandsDirectory = invocationDirectory.appending(path: "commands", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: commandsDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let invocationMetadata: [String: Any] = [
            "artifactContract": [
                "manifest.json", "verifier.log", "metadata.json", "stdout.txt", "stderr.txt", "result.json",
            ],
            "environmentKeys": environmentKeys,
            "invocationId": invocationID,
            "parentInvocationId": parentInvocationID ?? NSNull(),
            "runId": runID,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
        ]
        try writeJSON(invocationMetadata, to: invocationDirectory.appending(path: "invocation.json"))
    }

    private func invocationDirectory(runDirectory: URL) -> URL {
        runDirectory
            .appending(path: "invocations", directoryHint: .isDirectory)
            .appending(path: invocationID, directoryHint: .isDirectory)
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
                do {
                    try FileManager.default.createDirectory(
                        at: current,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                        throw ArtifactStoreError.unsafeRoot("artifact path contains a symbolic link")
                    }
                    var isDirectory = ObjCBool(false)
                    guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        throw error
                    }
                }
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
