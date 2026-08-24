// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func leaseProbeURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appending(path: "AxolotyDeviceLeaseProbe")
}

private func temporaryLeaseRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-device-leases-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct LeaseProbeOutcome {
    let exitCode: Int32?
    let standardOutput: String
    let standardError: String
    let timedOut: Bool

    var diagnostic: String {
        "exitCode=\(exitCode.map { String($0) } ?? "none"), timedOut=\(timedOut), " +
            "stdout=\(standardOutput.debugDescription), stderr=\(standardError.debugDescription)"
    }
}

private final class LeaseProbeProcess {
    let process: Process
    private let standardOutputCapture: ConcurrentPipeCapture
    private let standardErrorCapture: ConcurrentPipeCapture

    init(root: URL, device: String, ready: URL? = nil, hold: Bool = false) throws {
        let process = Process()
        let standardOutputCapture = ConcurrentPipeCapture()
        let standardErrorCapture = ConcurrentPipeCapture()
        self.process = process
        self.standardOutputCapture = standardOutputCapture
        self.standardErrorCapture = standardErrorCapture

        process.executableURL = leaseProbeURL()
        var arguments = ["--device", device]
        if let ready {
            arguments.append(contentsOf: ["--ready", ready.path])
        }
        if hold {
            arguments.append("--hold")
        }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AXOLOTY_DEVICE_LEASE_ROOT": root.path,
        ]) { _, value in value }
        process.standardOutput = standardOutputCapture.writer
        process.standardError = standardErrorCapture.writer
        do {
            try process.run()
        } catch {
            standardOutputCapture.closeWriter()
            standardErrorCapture.closeWriter()
            throw error
        }
        standardOutputCapture.closeWriter()
        standardErrorCapture.closeWriter()
    }

    func wait(timeout: Duration = .seconds(5)) -> LeaseProbeOutcome {
        let exited = waitForExit(timeout: timeout)
        if !exited {
            process.terminate()
            if !waitForExit(timeout: .seconds(1)) {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(timeout: .seconds(2))
            }
        }
        return outcome(timedOut: !exited)
    }

    func stop() -> LeaseProbeOutcome {
        if process.isRunning {
            process.terminate()
            if !waitForExit(timeout: .seconds(1)) {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(timeout: .seconds(2))
            }
        }
        return outcome(timedOut: process.isRunning)
    }

    func killAbruptly() -> LeaseProbeOutcome {
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(timeout: .seconds(2))
        }
        return outcome(timedOut: process.isRunning)
    }

    private func waitForExit(timeout: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func outcome(timedOut: Bool) -> LeaseProbeOutcome {
        let deadline = DispatchTime.now() + .seconds(2)
        return LeaseProbeOutcome(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            standardOutput: standardOutputCapture.output(waitUntil: deadline) ?? "<output drain timed out>",
            standardError: standardErrorCapture.output(waitUntil: deadline) ?? "<error drain timed out>",
            timedOut: timedOut
        )
    }
}

private func startLeaseProbe(root: URL, device: String, ready: URL) throws -> LeaseProbeProcess {
    try LeaseProbeProcess(root: root, device: device, ready: ready, hold: true)
}

private func acquireLeaseOnce(root: URL, device: String) throws -> LeaseProbeOutcome {
    try LeaseProbeProcess(root: root, device: device).wait()
}

private func waitForReady(_ path: URL, owner: LeaseProbeProcess) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: path.path) { return true }
        if !owner.process.isRunning { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private func requireReady(_ path: URL, owner: LeaseProbeProcess) -> Bool {
    guard waitForReady(path, owner: owner) else {
        let outcome = owner.stop()
        Issue.record("Lease owner did not report readiness: \(outcome.diagnostic)")
        return false
    }
    return true
}

@Test
func sameDeviceLeaseIsContendedAcrossProcesses() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/ttyACM0", ready: ready)
    defer {
        if owner.process.isRunning { _ = owner.stop() }
    }

    guard requireReady(ready, owner: owner) else { return }
    let contender = try acquireLeaseOnce(root: root, device: "/dev/./ttyACM0")
    #expect(contender.exitCode == 75, "\(contender.diagnostic)")
}

@Test
func differentDeviceLeasesCoexistAcrossProcesses() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/a-b", ready: ready)
    defer {
        if owner.process.isRunning { _ = owner.stop() }
    }

    guard requireReady(ready, owner: owner) else { return }
    let contender = try acquireLeaseOnce(root: root, device: "/dev/a_b")
    #expect(contender.exitCode == 0, "\(contender.diagnostic)")
}

@Test
func deadOwnerLeaseIsRecoverableByAnotherProcess() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/ttyACM0", ready: ready)

    guard requireReady(ready, owner: owner) else { return }
    let stoppedOwner = owner.killAbruptly()
    #expect(!stoppedOwner.timedOut, "\(stoppedOwner.diagnostic)")
    let successor = try acquireLeaseOnce(root: root, device: "/dev/ttyACM0")
    #expect(successor.exitCode == 0, "\(successor.diagnostic)")
}
