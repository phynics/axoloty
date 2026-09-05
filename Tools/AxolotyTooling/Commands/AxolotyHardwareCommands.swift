// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// A typed hardware-family command routed by ``AxolotyHardwareCommands``.
struct AxolotyHardwareCommand: Equatable, Sendable {
    let required: Bool
    let device: String?

    init(required: Bool, device: String?) {
        self.required = required
        self.device = device
    }
}

/// Executes the optional and required embedded hardware smoke checks.
struct AxolotyHardwareCommands: Sendable {
    private let commandRunner: any AxolotyCheckCommandRunning
    private let contextValidator: AxolotyExecutionContextValidator
    private let deviceLeaseManager: any AxolotyDeviceLeasing
    private let fileSystem: any AxolotyFileSystem
    private let environment: [String: String]

    init(
        commandRunner: any AxolotyCheckCommandRunning,
        contextValidator: AxolotyExecutionContextValidator,
        deviceLeaseManager: any AxolotyDeviceLeasing,
        fileSystem: any AxolotyFileSystem,
        environment: [String: String]
    ) {
        self.commandRunner = commandRunner
        self.contextValidator = contextValidator
        self.deviceLeaseManager = deviceLeaseManager
        self.fileSystem = fileSystem
        self.environment = environment
    }

    /// Executes one typed hardware-family command.
    func run(_ command: AxolotyHardwareCommand) -> AxolotyCommandResult {
        let selectedDevice = command.device ?? environment["AXOLOTY_DEVICE"] ?? "/dev/ttyACM0"
        let plan = AxolotyCommandPlan(
            executable: "Tests/Support/embedded/embedded-swift-test.sh",
            environment: ["EMBEDDED_DEVICE": selectedDevice],
            timeoutSeconds: 10 * 60
        )
        if let failure = contextValidator.failureResult(validating: [plan]) {
            return AxolotyCommandFamilySupport.commandResult(failure)
        }
        guard fileSystem.exists(atPath: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: command.required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device is not present"
            )
            return (try? AxolotyCommandFamilySupport.jsonResult(outcome, exitCode: command.required ? 1 : 0))
                ?? AxolotyCommandResult(exitCode: 70)
        }
        guard let lease = deviceLeaseManager.acquire(device: selectedDevice) else {
            let outcome = AxolotyHardwareOutcome(
                status: command.required ? .failed : .skipped,
                device: selectedDevice,
                reason: "device lease is unavailable"
            )
            return (try? AxolotyCommandFamilySupport.jsonResult(outcome, exitCode: command.required ? 1 : 0))
                ?? AxolotyCommandResult(exitCode: 70)
        }
        let result = commandRunner.run(plan)
        withExtendedLifetime(lease) {}
        let outcome = AxolotyHardwareOutcome(
            status: result.exitCode == 0 ? .passed : .failed,
            device: selectedDevice,
            reason: result.exitCode == 0
                ? "hardware smoke test passed"
                : (result.standardError.isEmpty
                    ? "hardware smoke test failed"
                    : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return (try? AxolotyCommandFamilySupport.jsonResult(outcome, exitCode: result.exitCode == 0 ? 0 : 1))
            ?? AxolotyCommandResult(exitCode: 70)
    }
}
