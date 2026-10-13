// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses and executes repository-authority validation output.
struct AxolotyRepositoryValidationCommands: Sendable {
    private let repositoryRoot: URL

    init(repositoryRoot: URL) {
        self.repositoryRoot = repositoryRoot
    }

    /// Parses and executes one repository validation command.
    func run(arguments: [String]) -> AxolotyCommandResult {
        var format = "human"
        var validateEmbeddedConsumerContract = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--embedded-consumer-contract":
                validateEmbeddedConsumerContract = true
            case "--json":
                format = "json"
            case "--format":
                guard index + 1 < arguments.count, ["human", "json"].contains(arguments[index + 1]) else {
                    return AxolotyCommandResult(
                        standardError: "error: repository validate --format requires human or json\n",
                        exitCode: 64
                    )
                }
                format = arguments[index + 1]
                index += 1
            case "--help", "-h":
                return AxolotyCommandResult(standardOutput: AxolotyCommandHelp.repositoryValidationUsage)
            default:
                return AxolotyCommandResult(
                    standardError: "error: unsupported repository validate option: \(arguments[index])\n",
                    exitCode: 64
                )
            }
            index += 1
        }
        let authorityReport = AxolotyRepositoryAuthorityValidator(root: repositoryRoot).validate()
        let contractFindings = validateEmbeddedConsumerContract
            ? AxolotyEmbeddedConsumerContractValidator(root: repositoryRoot).validate()
            : []
        let findings = (authorityReport.findings + contractFindings).sorted {
            ($0.path ?? "", $0.rule, $0.message) < ($1.path ?? "", $1.rule, $1.message)
        }
        let report = AxolotyRepositoryAuthorityReport(
            version: authorityReport.version,
            status: findings.isEmpty ? "passed" : "failed",
            findings: findings
        )
        if format == "json" {
            return (try? AxolotyCommandFamilySupport.jsonResult(report, exitCode: report.status == "passed" ? 0 : 1))
                ?? AxolotyCommandResult(standardError: "error: unable to encode repository authority report\n", exitCode: 70)
        }
        if report.findings.isEmpty {
            return AxolotyCommandResult(standardOutput: "repository authority: passed\n")
        }
        let lines = report.findings.map { finding in
            let location = finding.path.map { " [\($0)]" } ?? ""
            return "- \(finding.rule)\(location): \(finding.message)"
        }
        return AxolotyCommandResult(
            standardOutput: "repository authority: failed\n\(lines.joined(separator: "\n"))\n",
            exitCode: 1
        )
    }
}
