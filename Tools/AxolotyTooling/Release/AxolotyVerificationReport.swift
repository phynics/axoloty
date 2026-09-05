// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

struct AxolotyVerificationReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct Plan: Codable, Equatable, Sendable {
        let status: AxolotyCheckStatus
        let elapsedSeconds: TimeInterval
        let expectedDurationSeconds: TimeInterval?
        let deadlineSeconds: TimeInterval?
        let exceededExpectation: Bool
        let resourceLeaseWaitSeconds: TimeInterval
    }

    let schemaVersion: Int
    let runID: String
    let invocationID: String
    let parentInvocationID: String?
    let primary: Bool
    let generatedAt: String
    let plan: Plan
    let nodes: [AxolotyCheckResult]
}

enum AxolotyVerificationReportError: LocalizedError {
    case unsafeReportDirectory
    case invalidPrimaryReportCount(Int)
    case primaryReportAlreadyClaimed

    var errorDescription: String? {
        switch self {
        case .unsafeReportDirectory:
            "verification report directory is a symlink or is not a directory"
        case let .invalidPrimaryReportCount(count):
            "verify-ci requires exactly one primary report; found \(count)"
        case .primaryReportAlreadyClaimed:
            "verify-ci primary report was already claimed by another invocation"
        }
    }
}

struct AxolotyVerificationReportWriter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func write(
        plan: AxolotyCheckPlan,
        results: [AxolotyCheckResult],
        invocation: AxolotyArtifactInvocation
    ) throws -> (json: URL, markdown: URL) {
        try prepare(directory: invocation.reportDirectory)
        let existingPrimaryCount = try primaryReportCount(in: invocation.reportDirectory)
        guard existingPrimaryCount <= 1 else {
            throw AxolotyVerificationReportError.invalidPrimaryReportCount(existingPrimaryCount)
        }
        if invocation.parentInvocationID == nil {
            guard existingPrimaryCount == 0 else {
                throw AxolotyVerificationReportError.invalidPrimaryReportCount(existingPrimaryCount + 1)
            }
            try claimPrimaryReport(in: invocation.reportDirectory)
        }
        let elapsed = results.compactMap(\.timing?.elapsedSeconds).reduce(0, +)
        let leaseWait = results.compactMap(\.timing?.resourceLeaseWaitSeconds).reduce(0, +)
        let status: AxolotyCheckStatus = results.allSatisfy { $0.status == .passed } ? .passed : .failed
        let report = AxolotyVerificationReport(
            schemaVersion: AxolotyVerificationReport.currentSchemaVersion,
            runID: invocation.runID,
            invocationID: invocation.invocationID,
            parentInvocationID: invocation.parentInvocationID,
            primary: invocation.parentInvocationID == nil,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            plan: .init(
                status: status,
                elapsedSeconds: elapsed,
                expectedDurationSeconds: plan.expectedDurationSeconds,
                deadlineSeconds: plan.deadlineSeconds,
                exceededExpectation: plan.expectedDurationSeconds.map { elapsed >= $0 } ?? false,
                resourceLeaseWaitSeconds: leaseWait
            ),
            nodes: results
        )
        let basename = "\(invocation.invocationID)-verify-ci"
        let json = invocation.reportDirectory.appending(path: "\(basename).json")
        let markdownURL = invocation.reportDirectory.appending(path: "\(basename).md")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: json, options: .atomic)
        try Data(markdown(for: report).utf8).write(to: markdownURL, options: .atomic)
        if report.primary {
            let primaryCount = try primaryReportCount(in: invocation.reportDirectory)
            guard primaryCount == 1 else {
                throw AxolotyVerificationReportError.invalidPrimaryReportCount(primaryCount)
            }
        }
        return (json, markdownURL)
    }

    private func prepare(directory: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw AxolotyVerificationReportError.unsafeReportDirectory
            }
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func primaryReportCount(in directory: URL) throws -> Int {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix("-verify-ci.json") }
        let decoder = JSONDecoder()
        return try urls.reduce(into: 0) { count, url in
            let report = try decoder.decode(AxolotyVerificationReport.self, from: Data(contentsOf: url))
            if report.primary { count += 1 }
        }
    }

    private func claimPrimaryReport(in directory: URL) throws {
        let claim = directory.appending(path: ".primary-verify-ci-claim", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(
                at: claim,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw AxolotyVerificationReportError.primaryReportAlreadyClaimed
        }
    }

    private func markdown(for report: AxolotyVerificationReport) -> String {
        let slowest = report.nodes.compactMap { result -> (AxolotyCheckResult, AxolotyCheckTiming)? in
            result.timing.map { (result, $0) }
        }.sorted { $0.1.elapsedSeconds > $1.1.elapsedSeconds }.prefix(10)
        let overruns = report.nodes.filter { $0.timing?.exceededExpectation == true }
        let leaseWaits = report.nodes.filter { ($0.timing?.resourceLeaseWaitSeconds ?? 0) > 0 }
        let failures = report.nodes.filter { $0.status != .passed && $0.status != .skipped }
        let expected = report.plan.expectedDurationSeconds.map(seconds) ?? "not set"
        let deadline = report.plan.deadlineSeconds.map(seconds) ?? "not set"
        var lines = [
            "# Required Linux verification",
            "",
            "- Status: **\(report.plan.status.rawValue)**",
            "- Plan elapsed: \(seconds(report.plan.elapsedSeconds))",
            "- Expected duration: \(expected)",
            "- Hard deadline: \(deadline)",
            "- Resource lease wait: \(seconds(report.plan.resourceLeaseWaitSeconds))",
            "- Run: `\(report.runID)`",
            "- Invocation: `\(report.invocationID)`",
            "",
            "## Ten slowest nodes",
            "",
            "| Node | Status | Elapsed | Expected | Lease wait | Last test | Output | Artifact |",
            "| --- | --- | ---: | ---: | ---: | --- | ---: | --- |",
        ]
        lines += slowest.map { result, timing in
            let command = result.command
            let lastTest = command?.observation?.lastTest ?? command?.lifecycle?.lastTest
            let artifact = command?.observation?.artifactPath ?? command?.lifecycle?.artifactPath
            let expected = timing.expectedDurationSeconds.map(seconds) ?? "—"
            let outputBytes = command?.observation.map { String($0.outputBytes) } ?? "—"
            return "| \(cell(result.name)) | \(result.status.rawValue) | \(seconds(timing.elapsedSeconds)) | \(expected) | \(seconds(timing.resourceLeaseWaitSeconds)) | \(cell(lastTest ?? "—")) | \(outputBytes) | \(cell(artifact ?? "—")) |"
        }
        lines += section("Overruns", rows: overruns.map { result in
            let expected = result.timing?.expectedDurationSeconds.map(seconds) ?? "not set"
            return "- `\(result.name)`: \(seconds(result.timing?.elapsedSeconds ?? 0)) / \(expected)"
        })
        lines += section("Resource lease waits", rows: leaseWaits.map { result in
            "- `\(result.name)`: \(seconds(result.timing?.resourceLeaseWaitSeconds ?? 0))"
        })
        lines += section("Failure diagnostics", rows: failures.map { result in
            let diagnostic = result.command?.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = diagnostic?.isEmpty == false ? diagnostic! : "no diagnostic"
            return "- `\(result.name)` (\(result.status.rawValue)): \(cell(detail))"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private func section(_ title: String, rows: [String]) -> [String] {
        ["", "## \(title)", ""] + (rows.isEmpty ? ["None."] : rows)
    }

    private func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3fs", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
