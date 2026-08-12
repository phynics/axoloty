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

private func startLeaseProbe(root: URL, device: String, ready: URL) throws -> Process {
    let process = Process()
    process.executableURL = leaseProbeURL()
    process.arguments = ["--device", device, "--ready", ready.path, "--hold"]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "AXOLOTY_DEVICE_LEASE_ROOT": root.path,
    ]) { _, value in value }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func acquireLeaseOnce(root: URL, device: String) throws -> Int32 {
    let process = Process()
    process.executableURL = leaseProbeURL()
    process.arguments = ["--device", device]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "AXOLOTY_DEVICE_LEASE_ROOT": root.path,
    ]) { _, value in value }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func waitForReady(_ path: URL) -> Bool {
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: path.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private func stopAbruptly(_ process: Process) {
    _ = kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
}

@Test
func sameDeviceLeaseIsContendedAcrossProcesses() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/ttyACM0", ready: ready)
    defer {
        if owner.isRunning { stopAbruptly(owner) }
    }

    #expect(waitForReady(ready))
    #expect(try acquireLeaseOnce(root: root, device: "/dev/./ttyACM0") == 75)
}

@Test
func differentDeviceLeasesCoexistAcrossProcesses() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/a-b", ready: ready)
    defer {
        if owner.isRunning { stopAbruptly(owner) }
    }

    #expect(waitForReady(ready))
    #expect(try acquireLeaseOnce(root: root, device: "/dev/a_b") == 0)
}

@Test
func deadOwnerLeaseIsRecoverableByAnotherProcess() throws {
    let root = try temporaryLeaseRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appending(path: "owner-ready")
    let owner = try startLeaseProbe(root: root, device: "/dev/ttyACM0", ready: ready)

    #expect(waitForReady(ready))
    stopAbruptly(owner)
    #expect(try acquireLeaseOnce(root: root, device: "/dev/ttyACM0") == 0)
}
