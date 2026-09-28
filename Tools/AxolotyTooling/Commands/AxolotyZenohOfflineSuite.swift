// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Runs every router-free AxolotyZenoh package test against the pinned zenoh-c
/// archive inside the pinned project container. It never starts `zenohd`.
struct AxolotyZenohOfflineSuite {
    /// The suite that needs a live router; it stays in the opt-in zenoh-live tier.
    static let liveSuite = "ZenohLiveIntegrationTests"

    private let environment: [String: String]
    private let root: URL
    private let toolchain: AxolotyZenohToolchain

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        toolchain = AxolotyZenohToolchain(environment: environment)
        root = URL(fileURLWithPath: environment["WORKDIR"] ?? FileManager.default.currentDirectoryPath)
            .standardizedFileURL
    }

    func run() -> AxolotyCommandResult {
        do {
            try execute()
            return AxolotyCommandResult(standardOutput: "PASS: offline Zenoh package tests completed\n")
        } catch {
            return AxolotyCommandResult(
                standardError: "FAIL: offline Zenoh package tests: \(error.localizedDescription)\n",
                exitCode: 1
            )
        }
    }

    private func execute() throws(AxolotyZenohCommandError) {
        guard AxolotyCheckPlan.currentPlatform == .linux else {
            throw .invalidOutput("the pinned zenoh-offline tier requires Linux")
        }
        let zenohC = try toolchain.provisionZenohC(
            in: root.appending(path: ".build/zenoh-offline/dependencies/zenoh-c")
        )
        print("ZENOH_OFFLINE_C_READY version=\(AxolotyZenohToolchain.version)")
        // An inherited live endpoint would enable the router suite; this tier
        // proves the package without one.
        let childEnvironment = zenohC.environment(extending: environment)
            .filter { !$0.key.hasPrefix("AXOLOTY_ZENOH_LIVE_") }
        try toolchain.runCommand(
            "swift",
            arguments: [
                "test", "--package-path", "Packages/AxolotyZenoh",
                "--scratch-path", ".build/zenoh-offline/swift",
                "--cache-path", ".swiftpm-cache", "--disable-automatic-resolution",
                "--skip", Self.liveSuite,
            ],
            environment: childEnvironment,
            streamsOutput: true
        )
    }
}
