// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

// The serve implementation lives in the AxolotyDebug package. These tests only
// exercise how the `ax` dispatcher routes into it.

@Test(arguments: ["mqtt", "mcp", "dev"])
func dispatcherServeSubcommandHelpPrintsContextualUsage(subcommand: String) {
    let dispatcher = AxolotyCommandDispatcher(
        executableName: "ax",
        environment: [:],
        installSignalHandler: false
    )

    let result = dispatcher.run(arguments: ["serve", subcommand, "--help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: ax serve \(subcommand)"))
    #expect(result.standardOutput.contains("Options:"))
    #expect(result.standardError.isEmpty)
}

@Test
func dispatcherServesMcpMissingTransportReturnsError() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["serve", "mcp"])
    #expect(result.exitCode == 64)
    #expect(result.standardError.contains("transport"))
}

@Test
func dispatcherServeUnknownSubcommandReturnsError() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["serve", "unknown"])
    #expect(result.exitCode == 64)
}

@Test
func dispatcherVersionUsesExecutableName() {
    let dispatcher = AxolotyCommandDispatcher(executableName: "ax", environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "ax 0.9.0")
}

@Test
func dispatcherDefaultVersionIsAxolotyTool() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "axoloty-tool 0.9.0")
}

@Test
func dispatcherHelpIncludesServeCommands() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["help"])
    #expect(result.standardOutput.contains("serve mqtt"))
    #expect(result.standardOutput.contains("serve mcp"))
    #expect(result.standardOutput.contains("serve dev"))
}
