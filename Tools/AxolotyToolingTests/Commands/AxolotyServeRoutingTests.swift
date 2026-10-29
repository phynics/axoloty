// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

// The serve implementation and entry point live in the sibling axoloty-debug
// package. This file keeps the harness-level surface that references the
// executable version and command help.

@Test
func dispatcherVersionUsesExecutableName() {
    let dispatcher = AxolotyCommandDispatcher(executableName: "ax", environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "ax 0.10.0")
}

@Test
func dispatcherDefaultVersionIsAxolotyTool() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["version"])
    #expect(result.standardOutput == "axoloty-tool 0.10.0")
}

@Test
func dispatcherHelpListsOrchestrationCommands() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["help"])
    #expect(result.standardOutput.contains("verify"))
    #expect(result.standardOutput.contains("test-tier"))
    #expect(result.standardOutput.contains("repository validate"))
    #expect(result.standardOutput.contains("axoloty-debug"))
}

@Test
func dispatcherRejectsTheMovedServeCommand() {
    let dispatcher = AxolotyCommandDispatcher(environment: [:])
    let result = dispatcher.run(arguments: ["serve", "mqtt"])
    #expect(result.exitCode == 64)
}
