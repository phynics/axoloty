// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A held, process-scoped lease for one configured hardware device.
public protocol AxolotyDeviceLease: AnyObject, Sendable {}

/// Acquires non-blocking, device-specific leases for hardware operations.
public protocol AxolotyDeviceLeasing: Sendable {
    /// Attempts to acquire a lease for the configured device path.
    func acquire(device: String) -> (any AxolotyDeviceLease)?
}

private final class FoundationDeviceLease: AxolotyDeviceLease, @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
    }
}

/// Foundation/POSIX implementation using a process-aware advisory file lock.
public struct FoundationDeviceLeaseManager: AxolotyDeviceLeasing {
    private static let leaseRootEnvironmentVariable = "AXOLOTY_DEVICE_LEASE_ROOT"
    private let leaseRoot: URL

    /// Creates a device lease manager.
    ///
    /// The lease root is read from `AXOLOTY_DEVICE_LEASE_ROOT` when it is
    /// configured. Otherwise, leases retain their historical temporary
    /// directory default.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        let configuredRoot = environment[Self.leaseRootEnvironmentVariable]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        self.init(root: configuredRoot ?? URL(filePath: NSTemporaryDirectory()))
    }

    /// Creates a device lease manager rooted at the supplied directory.
    ///
    /// - Parameter root: The directory shared by processes that must contend
    ///   for device leases.
    public init(root: URL) {
        leaseRoot = root.standardizedFileURL
    }

    /// Creates a device lease manager rooted at the supplied directory.
    ///
    /// - Parameter leaseRoot: The directory shared by processes that must
    ///   contend for device leases.
    public init(leaseRoot: URL) {
        self.init(root: leaseRoot)
    }

    /// Acquires a non-blocking lock keyed by the configured device path.
    public func acquire(device: String) -> (any AxolotyDeviceLease)? {
        guard !device.isEmpty else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: leaseRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }

        let canonicalDevicePath = URL(
            fileURLWithPath: device,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
        let encodedPath = Data(canonicalDevicePath.utf8)
            .base64EncodedString()
            // `_` is not in the Base64 alphabet, so this substitution is
            // injective while keeping the key a single filename component.
            .replacingOccurrences(of: "/", with: "_")
        let path = leaseRoot
            .appending(path: "axoloty-hardware-\(encodedPath).lock")
            .path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            return nil
        }
        return FoundationDeviceLease(descriptor: descriptor)
    }
}
