// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Testing

private func commandHelpDispatcher(executableName: String = "axoloty-tool") -> AxolotyCommandDispatcher {
    AxolotyCommandDispatcher(
        executableName: executableName,
        environment: [:],
        installSignalHandler: false
    )
}

@Test
func rootHelpAliasesRemainByteIdentical() {
    let dispatcher = commandHelpDispatcher()
    let outputs = [[], ["help"], ["--help"], ["-h"]].map {
        dispatcher.run(arguments: $0)
    }

    #expect(outputs.dropFirst().allSatisfy { $0 == outputs[0] })
    #expect(outputs[0].exitCode == 0)
    #expect(outputs[0].standardError.isEmpty)
}

@Test
func timingHelpUsesConfiguredExecutableName() {
    let result = commandHelpDispatcher(executableName: "ax").run(
        arguments: ["measure", "timing", "--help"]
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput.hasPrefix("Usage: ax measure timing [options]\n"))
    #expect(result.standardOutput.contains("--scratch-root PATH"))
    #expect(!result.standardOutput.contains("axoloty-tool"))
    #expect(result.standardError.isEmpty)
}

@Test
func repositoryValidationHelpKeepsStableUsageDocument() {
    let result = commandHelpDispatcher().run(
        arguments: ["repository", "validate", "--help"]
    )

    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "Usage: axoloty-tool repository validate [--format human|json]\n")
    #expect(result.standardError.isEmpty)
}
