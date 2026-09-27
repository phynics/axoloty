// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

extension AxolotyCheckTests {

/// A command runner that reports the synthetic empty-test exit code for a
/// chosen set of packages and records the package of every command it sees.
private final class PackageRecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let emptyPackages: Set<String>

    init(emptyPackages: Set<String>) {
        self.emptyPackages = emptyPackages
    }

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        let package: String
        if let index = command.arguments.firstIndex(of: "--package-path"),
           command.arguments.index(after: index) < command.arguments.endIndex {
            package = command.arguments[command.arguments.index(after: index)]
        } else {
            package = "."
        }
        lock.lock()
        storage.append(package)
        lock.unlock()
        guard emptyPackages.contains(package) else {
            return AxolotyCheckCommandResult(exitCode: 0, standardOutput: "ran \(package)\n")
        }
        return AxolotyCheckCommandResult(
            exitCode: FoundationCommandExecution.emptyTestRunExitCode,
            standardError: "warning: No matching test cases were run\n"
        )
    }

    var packages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func makeCheckCommands(
    runner: PackageRecordingRunner
) throws -> AxolotyCheckCommands {
    let resolver = try AxolotyCanonicalTestPlanResolver(environment: ProcessInfo.processInfo.environment)
    let validator = AxolotyExecutionContextValidator(
        environment: ["AXOLOTY_DEVCONTAINER": "1"],
        platform: .linux
    )
    return AxolotyCheckCommands(
        commandRunner: runner,
        contextValidator: validator,
        outputMode: .json,
        planResolver: .success(resolver),
        executor: AxolotyCheckExecutor(commandRunner: runner, contextValidator: validator)
    )
}

@Test
func testOneFallsThroughPackagesUntilAFilterMatches() throws {
    let runner = PackageRecordingRunner(emptyPackages: ["."])
    let commands = try makeCheckCommands(runner: runner)

    let result = commands.run(.testOne(filter: "SomeUnlistedToolingSuite", repetition: nil))

    #expect(result.exitCode == 0)
    // The root package is tried first for an unlisted filter, then Tools.
    #expect(runner.packages == [".", "Tools"])
}

@Test
func testOneNoMatchNamesEverySearchedPackage() throws {
    let runner = PackageRecordingRunner(emptyPackages: [".", "Tools", "Apps"])
    let commands = try makeCheckCommands(runner: runner)

    let result = commands.run(.testOne(filter: "MissingSuite", repetition: nil))

    #expect(result.exitCode != 0)
    #expect(result.standardError.contains("MissingSuite"))
    #expect(result.standardError.contains("root (.)"))
    #expect(result.standardError.contains("Tools"))
    #expect(result.standardError.contains("Apps"))
    #expect(runner.packages == [".", "Tools", "Apps"])
}

}
