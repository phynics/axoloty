// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyTooling
import Testing

@Test
func helpCommandPrintsUsage() {
    let result = AxolotyCommandDispatcher().run(arguments: ["help"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.contains("Usage: ax <command>"))
    #expect(result.standardError.isEmpty)
}

@Test
func versionCommandPrintsVersion() {
    let result = AxolotyCommandDispatcher().run(arguments: ["--version"])

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "ax 0.1.0")
    #expect(result.standardError.isEmpty)
}

@Test
func unknownCommandReturnsUsageError() {
    let result = AxolotyCommandDispatcher().run(arguments: ["check"])

    #expect(result.exitCode == 64)
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardError.contains("unsupported ax command"))
    #expect(result.standardError.contains("Usage: ax <command>"))
}
