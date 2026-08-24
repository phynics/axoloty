// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func resourceProbeURL() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appending(path: "AxolotyResourceLeaseProbe")
}

private func temporaryResourceLeaseRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "axoloty-resource-leases-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct ResourceProbeOutcome {
    let exitCode: Int32?
    let standardError: String
    let timedOut: Bool
}

private final class ResourceLeaseProbeProcess {
    let process: Process
    private let errorPipe: Pipe

    init(root: URL, resource: String, ready: URL? = nil, timeout: TimeInterval = 0, hold: Bool = false) throws {
        let process = Process()
        let errorPipe = Pipe()
        self.process = process
        self.errorPipe = errorPipe
        process.executableURL = resourceProbeURL()
        var arguments = ["--resource", resource, "--timeout", String(timeout)]
        if let ready { arguments.append(contentsOf: ["--ready", ready.path]) }
        if hold { arguments.append("--hold") }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AXOLOTY_RESOURCE_LEASE_ROOT": root.path,
        ]) { _, value in value }
        process.standardError = errorPipe
        try process.run()
    }

    func wait(timeout: TimeInterval = 5) -> ResourceProbeOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Self.milliseconds(timeout)))
        while process.isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = reap(timeout: .seconds(2))
        }
        let error = process.isRunning
            ? ""
            : String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ResourceProbeOutcome(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            standardError: error,
            timedOut: timedOut
        )
    }

    private func reap(timeout: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64(min(max(0, seconds) * 1_000, Double(Int64.max)))
    }

    func stopAbruptly() -> ResourceProbeOutcome {
        guard process.isRunning else { return wait(timeout: 1) }
        _ = kill(process.processIdentifier, SIGKILL)
        return wait(timeout: 2)
    }
}

private final class RecordingLease: AxolotyResourceLease, @unchecked Sendable {}

private final class RecordingLeaseManager: AxolotyResourceLeasing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquiredResources: [String] = []
    private(set) var acquiredTimeouts: [TimeInterval?] = []

    func acquire(
        resource: String,
        timeoutSeconds: TimeInterval?,
        owner: String
    ) throws -> any AxolotyResourceLease {
        lock.lock()
        acquiredResources.append(resource)
        acquiredTimeouts.append(timeoutSeconds)
        lock.unlock()
        return RecordingLease()
    }
}

private struct SuccessfulCheckRunner: AxolotyCheckCommandRunning {
    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        AxolotyCheckCommandResult(exitCode: 0)
    }
}

private func waitForReady(_ path: URL, owner: ResourceLeaseProbeProcess) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path.path) { return true }
        if !owner.process.isRunning { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

@Test
func namedResourceLeaseReportsOwnerAndBoundsContention() throws {
    let root = try temporaryResourceLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try ResourceLeaseProbeProcess(
        root: root,
        resource: "fixed-port-1883",
        ready: ready,
        timeout: 0,
        hold: true
    )
    defer { if owner.process.isRunning { _ = owner.stopAbruptly() } }
    #expect(waitForReady(ready, owner: owner))

    let contender = try ResourceLeaseProbeProcess(
        root: root,
        resource: "fixed-port-1883",
        timeout: 0.15
    ).wait()
    #expect(!contender.timedOut)
    #expect(contender.exitCode == 75)
    #expect(contender.standardError.contains("resource lease busy"))
    #expect(contender.standardError.contains("resource-probe"))
}

@Test
func deadResourceLeaseOwnerIsRecoverableByAnotherProcess() throws {
    let root = try temporaryResourceLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try ResourceLeaseProbeProcess(
        root: root,
        resource: "fixed-port-1883",
        ready: ready,
        hold: true
    )
    #expect(waitForReady(ready, owner: owner))
    let stopped = owner.stopAbruptly()
    #expect(!stopped.timedOut)

    let successor = try ResourceLeaseProbeProcess(
        root: root,
        resource: "fixed-port-1883"
    ).wait()
    #expect(successor.exitCode == 0)
}

@Test
func independentNamedResourceLeasesCoexist() throws {
    let root = try temporaryResourceLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ResourceLeaseProbeProcess(root: root, resource: "fixed-port-1883").wait()
    let second = try ResourceLeaseProbeProcess(root: root, resource: "wire-containers").wait()
    #expect(first.exitCode == 0)
    #expect(second.exitCode == 0)
}

@Test
func executorLeasesOnlyCollisionProneDeclaredResources() {
    let manager = RecordingLeaseManager()
    let validator = AxolotyExecutionContextValidator(environment: ["AXOLOTY_DEVCONTAINER": "1"])
    let node = AxolotyCheckNode(
        name: "resource-owner",
        command: AxolotyCommandPlan(executable: "resource-owner"),
        resources: ["source-tree", "wire-containers", "swiftpm-build", "fixed-port-1883"]
    )
    let results = AxolotyCheckExecutor(
        commandRunner: SuccessfulCheckRunner(),
        contextValidator: validator,
        resourceLeaseManager: manager
    ).execute(AxolotyCheckPlan(nodes: [node]))

    #expect(results.map(\.status) == [.passed])
    #expect(manager.acquiredResources == ["fixed-port-1883", "wire-containers"])
    #expect(manager.acquiredTimeouts == [30, 30])
}
