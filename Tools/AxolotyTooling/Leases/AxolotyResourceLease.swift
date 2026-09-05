// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A held process-scoped lease for one named external resource.
public protocol AxolotyResourceLease: AnyObject, Sendable {}

/// Acquires bounded, process-aware leases for named external resources.
public protocol AxolotyResourceLeasing: Sendable {
    /// Acquires a lease, waiting no longer than the supplied timeout.
    ///
    /// - Parameters:
    ///   - resource: A stable resource name such as `fixed-port-1883`.
    ///   - timeoutSeconds: The maximum wait in seconds. `nil` means no wait
    ///     limit, which is intended only for callers with an outer deadline.
    ///   - owner: A diagnostic owner description written beside the lock.
    /// - Returns: The held lease. Releasing it closes the process-owned lock.
    /// - Throws: ``AxolotyResourceLeaseError`` when the resource cannot be
    ///   acquired or the request is invalid.
    func acquire(
        resource: String,
        timeoutSeconds: TimeInterval?,
        owner: String
    ) throws -> any AxolotyResourceLease
}
/// Errors emitted while acquiring a named resource lease.
public enum AxolotyResourceLeaseError: Error, Equatable, Sendable {
    /// The resource name was empty or unsafe for use as a lease key.
    case invalidResource(String)
    /// The timeout was negative, non-finite, or otherwise invalid.
    case invalidTimeout
    /// The lease directory could not be prepared.
    case unavailable(path: String, reason: String)
    /// Another process owns the resource when the bounded wait expires.
    case busy(resource: String, owner: String?)
}

extension AxolotyResourceLeaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResource(let resource):
            return "invalid resource lease name: \(resource)"
        case .invalidTimeout:
            return "invalid resource lease timeout"
        case .unavailable(let path, let reason):
            return "resource lease directory unavailable: path=\(path) reason=\(reason)"
        case .busy(let resource, let owner):
            let ownerDescription = owner.map { " owner=\($0)" } ?? " owner=unknown"
            return "resource lease busy: resource=\(resource)\(ownerDescription)"
        }
    }
}

private final class FoundationResourceLease: AxolotyResourceLease, @unchecked Sendable {
    private let descriptor: Int32
    private let ownerURL: URL
    private let ownerRecord: String
    private var released = false

    init(descriptor: Int32, ownerURL: URL, ownerRecord: String) {
        self.descriptor = descriptor
        self.ownerURL = ownerURL
        self.ownerRecord = ownerRecord
    }

    deinit {
        release()
    }

    private func release() {
        guard !released else { return }
        released = true
        // Remove the record while the advisory lock is still held. This keeps
        // a successor from observing or deleting a new owner's metadata.
        if let current = try? String(contentsOf: ownerURL, encoding: .utf8), current == ownerRecord {
            try? FileManager.default.removeItem(at: ownerURL)
        }
        _ = close(descriptor)
    }
}

/// Foundation/POSIX implementation using process-aware advisory file locks.
public struct FoundationResourceLeaseManager: AxolotyResourceLeasing {
    private static let rootEnvironmentVariable = "AXOLOTY_RESOURCE_LEASE_ROOT"
    private let root: URL

    /// Creates a manager using `AXOLOTY_RESOURCE_LEASE_ROOT`, or a shared
    /// temporary directory when no root is configured.
    public init() {
        self.init(environment: ProcessInfo.processInfo.environment)
    }

    /// Creates a manager from an environment snapshot.
    ///
    /// - Parameter environment: Environment used to select the lease root.
    public init(environment: [String: String]) {
        let configuredRoot = environment[Self.rootEnvironmentVariable]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        self.init(root: configuredRoot ?? URL(filePath: NSTemporaryDirectory()).appending(path: "axoloty-resource-leases"))
    }

    /// Creates a manager rooted at the supplied directory.
    ///
    /// - Parameter root: Directory shared by processes that must contend for
    ///   the same named resources.
    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Acquires a named lease with a bounded wait and owner diagnostics.
    public func acquire(
        resource: String,
        timeoutSeconds: TimeInterval? = 0,
        owner: String = "unknown"
    ) throws -> any AxolotyResourceLease {
        guard Self.isSafeResource(resource) else {
            throw AxolotyResourceLeaseError.invalidResource(resource)
        }
        if let timeoutSeconds,
           !timeoutSeconds.isFinite || timeoutSeconds < 0 {
            throw AxolotyResourceLeaseError.invalidTimeout
        }

        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw AxolotyResourceLeaseError.unavailable(path: root.path, reason: error.localizedDescription)
        }

        let key = Data(resource.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
        let lockURL = root.appending(path: "axoloty-resource-\(key).lock")
        let ownerURL = root.appending(path: "axoloty-resource-\(key).owner")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw AxolotyResourceLeaseError.unavailable(
                path: lockURL.path,
                reason: String(cString: strerror(errno))
            )
        }

        return try acquireLocked(
            descriptor: descriptor,
            ownerURL: ownerURL,
            resource: resource,
            timeoutSeconds: timeoutSeconds,
            owner: owner
        )
    }

    private func acquireLocked(
        descriptor: Int32,
        ownerURL: URL,
        resource: String,
        timeoutSeconds: TimeInterval?,
        owner: String
    ) throws -> any AxolotyResourceLease {
        let clock = ContinuousClock()
        let deadline = timeoutSeconds.map { timeout in
            let milliseconds = Int64(min(timeout * 1_000, Double(Int64.max)))
            return clock.now.advanced(by: .milliseconds(milliseconds))
        }
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                let record = Self.ownerRecord(resource: resource, owner: owner)
                do {
                    try Data(record.utf8).write(to: ownerURL, options: .atomic)
                } catch {
                    _ = close(descriptor)
                    throw AxolotyResourceLeaseError.unavailable(
                        path: ownerURL.path,
                        reason: error.localizedDescription
                    )
                }
                return FoundationResourceLease(
                    descriptor: descriptor,
                    ownerURL: ownerURL,
                    ownerRecord: record
                )
            }

            if let deadline, clock.now >= deadline {
                _ = close(descriptor)
                let ownerRecord = try? String(contentsOf: ownerURL, encoding: .utf8)
                throw AxolotyResourceLeaseError.busy(
                    resource: resource,
                    owner: ownerRecord?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func isSafeResource(_ resource: String) -> Bool {
        guard !resource.isEmpty, resource != ".", resource != ".." else { return false }
        return resource.allSatisfy { $0.isLetter || $0.isNumber || ".-_".contains($0) }
    }

    private static func ownerRecord(resource: String, owner: String) -> String {
        let safeOwner = owner.replacingOccurrences(of: "\n", with: " ")
        return "pid=\(getpid())\nresource=\(resource)\nowner=\(safeOwner)\nstarted-at=\(ISO8601DateFormatter().string(from: Date()))\n"
    }
}
