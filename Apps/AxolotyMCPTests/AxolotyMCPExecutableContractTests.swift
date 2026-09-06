// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Testing

@Test("MCP executable rejects invalid broker port")
func executableRejectsInvalidBrokerPort() throws {
    let result = try runMCPExecutable(arguments: ["--broker-port", "0"])

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid broker port"))
}

@Test("MCP executable rejects invalid listen port")
func executableRejectsInvalidListenPort() throws {
    let result = try runMCPExecutable(arguments: ["--listen-port", "70000"])

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid listen port"))
}

@Test("MCP executable rejects invalid endpoint path with managed-service error")
func executableRejectsInvalidEndpointPathWithManagedServiceError() throws {
    let result = try runMCPExecutable(
        arguments: ["--transport", "http", "--path", "mcp"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError == "error: invalid endpoint path: mcp (must start with /)\n")
}

@Test("Direct and managed MCP path validation have identical outcomes")
func mcpPathValidationParityMatrix() throws {
    let cases: [(path: String, expectedError: AxolotyServeError?)] = [
        ("", .invalidPath("")),
        ("mcp", .invalidPath("mcp")),
        ("/api/mcp", nil),
    ]

    for testCase in cases {
        let directResult = try runMCPExecutableForPathValidation(
            arguments: ["--transport", "http", "--path=\(testCase.path)", "--connect-timeout", "30s"]
        )
        let managedResult = AxolotyServeParser().parse(
            arguments: ["mcp", "--transport", "http", "--path=\(testCase.path)"],
            environment: [:]
        )

        if let expectedError = testCase.expectedError {
            let expectedMessage = expectedError.userFriendlyMessage
            #expect(directResult == .rejected(
                exitCode: 64,
                standardError: "error: \(expectedMessage)\n"
            ))
            guard case .failure(let managedError) = managedResult else {
                Issue.record("managed validation accepted invalid path '\(testCase.path)'")
                continue
            }
            #expect(managedError == expectedError)
            #expect(managedError.userFriendlyMessage == expectedMessage)
        } else {
            #expect(directResult == .accepted)
            guard case .success(.mcp(let configuration)) = managedResult else {
                Issue.record("managed validation rejected valid path '\(testCase.path)'")
                continue
            }
            #expect(configuration.path == testCase.path)
        }
    }
}

@Test("MCP executable routes --path= through shared validation")
func executableRejectsEmptyEqualsPathWithManagedServiceError() throws {
    let result = try runMCPExecutable(arguments: ["--transport", "http", "--path="])

    #expect(result.exitCode == 64)
    #expect(result.standardError == "error: invalid endpoint path:  (must start with /)\n")
}

@Test("Managed MCP parser distinguishes missing from explicitly empty path")
func managedParserDistinguishesMissingAndEmptyPath() {
    let missing = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "http", "--path"],
        environment: [:]
    )
    let empty = AxolotyServeParser().parse(
        arguments: ["mcp", "--transport", "http", "--path", ""],
        environment: [:]
    )

    #expect(missing == .failure(.missingValue("path")))
    #expect(empty == .failure(.invalidPath("")))
}

@Test("MCP executable rejects invalid connect timeout")
func executableRejectsInvalidConnectTimeout() throws {
    let result = try runMCPExecutable(
        arguments: ["--connect-timeout", "9223372036854775807m"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("invalid connect timeout"))
}

@Test("MCP executable rejects invalid environment ports")
func executableRejectsInvalidEnvironmentPorts() throws {
    let brokerResult = try runMCPExecutable(
        arguments: [],
        environment: ["AXOLOTY_MQTT_PORT": "invalid"]
    )
    let listenResult = try runMCPExecutable(
        arguments: [],
        environment: ["AXOLOTY_MCP_PORT": "0"]
    )

    #expect(brokerResult.exitCode == 64)
    #expect(brokerResult.standardError.contains("invalid broker port"))
    #expect(listenResult.exitCode == 64)
    #expect(listenResult.standardError.contains("invalid listen port"))
}

@Test("MCP executable CLI port overrides invalid environment value")
func executableCLIOverridesInvalidEnvironmentPort() throws {
    let result = try runMCPExecutable(
        arguments: ["--broker-port", "1883", "--transport", "invalid"],
        environment: ["AXOLOTY_MQTT_PORT": "0"]
    )

    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("unknown transport"))
    #expect(!result.standardError.contains("invalid broker port"))
}
