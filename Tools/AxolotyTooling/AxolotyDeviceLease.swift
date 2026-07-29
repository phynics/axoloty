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
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

/// Foundation/POSIX implementation using a process-aware advisory file lock.
public struct FoundationDeviceLeaseManager: AxolotyDeviceLeasing {
    /// Creates a device lease manager.
    public init() {}

    /// Acquires a non-blocking lock keyed by the configured device path.
    public func acquire(device: String) -> (any AxolotyDeviceLease)? {
        let key = device.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let path = URL(filePath: NSTemporaryDirectory())
            .appending(path: "axoloty-hardware-\(String(key)).lock")
            .path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            return nil
        }
        return FoundationDeviceLease(descriptor: descriptor)
    }
}
