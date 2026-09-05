// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

@Test
func verificationReportCoversEveryTerminalStatusAndDiagnostics() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-verification-report-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let invocation = AxolotyArtifactInvocation(
        runID: "report-run",
        invocationID: "primary",
        parentInvocationID: nil,
        reportDirectory: root.appending(path: "reports")
    )
    let statuses: [AxolotyCheckStatus] = [.passed, .failed, .expired, .skipped]
    var results = statuses.enumerated().map { index, status in
        AxolotyCheckResult(
            name: "node-\(status.rawValue)",
            status: status,
            command: status == .skipped ? nil : AxolotyCheckCommandResult(
                exitCode: status == .passed ? 0 : 1,
                standardError: status == .passed ? "" : "diagnostic-\(status.rawValue)",
                observation: status == .passed ? AxolotyCommandObservation(
                    elapsedSeconds: 2,
                    lastTest: "test-name",
                    outputBytes: 42,
                    artifactPath: "/artifacts/node-passed"
                ) : nil
            ),
            timing: status == .skipped ? nil : AxolotyCheckTiming(
                elapsedSeconds: TimeInterval(index + 1),
                expectedDurationSeconds: index == 1 ? 1 : 10,
                resourceLeaseWaitSeconds: index == 2 ? 0.5 : 0
            )
        )
    }
    results += [
        AxolotyCheckResult(
            name: "node-timed-out",
            status: .failed,
            command: AxolotyCheckCommandResult(
                exitCode: 124,
                standardError: "timed out",
                lifecycle: AxolotyCommandLifecycle(
                    outcome: .timedOut,
                    elapsedSeconds: 30,
                    lastTest: "slow-test",
                    artifactPath: "/artifacts/timed-out",
                    outputBytes: 100
                )
            ),
            timing: AxolotyCheckTiming(
                elapsedSeconds: 30,
                expectedDurationSeconds: 10,
                resourceLeaseWaitSeconds: 0
            )
        ),
        AxolotyCheckResult(
            name: "node-cancelled",
            status: .failed,
            command: AxolotyCheckCommandResult(
                exitCode: 130,
                standardError: "cancelled",
                lifecycle: AxolotyCommandLifecycle(outcome: .cancelled, elapsedSeconds: 3)
            ),
            timing: AxolotyCheckTiming(
                elapsedSeconds: 3,
                expectedDurationSeconds: 10,
                resourceLeaseWaitSeconds: 0
            )
        ),
        AxolotyCheckResult(
            name: "node-lease-failed",
            status: .failed,
            command: AxolotyCheckCommandResult(exitCode: 75, standardError: "unable to acquire resource lease"),
            timing: AxolotyCheckTiming(
                elapsedSeconds: 2,
                expectedDurationSeconds: 10,
                resourceLeaseWaitSeconds: 2
            )
        ),
    ]
    let plan = AxolotyCheckPlan(
        nodes: results.map { result in
            AxolotyCheckNode(name: result.name, command: AxolotyCommandPlan(executable: result.name))
        },
        deadlineSeconds: 80,
        expectedDurationSeconds: 20
    )

    let urls = try AxolotyVerificationReportWriter().write(
        plan: plan,
        results: results,
        invocation: invocation
    )
    let report = try JSONDecoder().decode(
        AxolotyVerificationReport.self,
        from: Data(contentsOf: urls.json)
    )
    let markdown = try String(contentsOf: urls.markdown, encoding: .utf8)

    #expect(report.schemaVersion == 1)
    #expect(report.primary)
    #expect(Array(report.nodes.prefix(statuses.count)).map(\.status) == statuses)
    #expect(markdown.contains("Ten slowest nodes"))
    #expect(markdown.contains("Overruns"))
    #expect(markdown.contains("Resource lease waits"))
    #expect(markdown.contains("diagnostic-failed"))
    #expect(markdown.contains("test-name"))
    #expect(markdown.contains("node-timed-out"))
    #expect(markdown.contains("node-cancelled"))
    #expect(markdown.contains("node-lease-failed"))
}

@Test
func verificationReportRejectsMultiplePrimaryReports() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-verification-report-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "reports")
    let plan = AxolotyCheckPlan(nodes: [])
    let writer = AxolotyVerificationReportWriter()
    _ = try writer.write(
        plan: plan,
        results: [],
        invocation: AxolotyArtifactInvocation(
            runID: "report-run",
            invocationID: "first",
            parentInvocationID: nil,
            reportDirectory: directory
        )
    )

    #expect(throws: AxolotyVerificationReportError.self) {
        _ = try writer.write(
            plan: plan,
            results: [],
            invocation: AxolotyArtifactInvocation(
                runID: "report-run",
                invocationID: "second",
                parentInvocationID: nil,
                reportDirectory: directory
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "second-verify-ci.json").path))
}

@Test
func verificationReportRejectsIncompleteExistingReport() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-verification-report-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "reports")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: directory.appending(path: "incomplete-verify-ci.json"))

    #expect(throws: DecodingError.self) {
        _ = try AxolotyVerificationReportWriter().write(
            plan: AxolotyCheckPlan(nodes: []),
            results: [],
            invocation: AxolotyArtifactInvocation(
                runID: "report-run",
                invocationID: "primary",
                parentInvocationID: nil,
                reportDirectory: directory
            )
        )
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "primary-verify-ci.json").path))
}

}
