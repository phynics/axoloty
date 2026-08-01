// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A specification for starting a managed child process.
public struct ManagedProcessSpecification: Sendable, Equatable {
    /// The executable path.
    public let executable: String
    /// Arguments to pass to the executable.
    public let arguments: [String]
    /// Optional environment overrides (merged with parent).
    public let environment: [String: String]?

    /// Creates a process specification.
    public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

/// The exit state of a managed child process.
public struct ManagedProcessExit: Sendable, Equatable {
    /// The process exit code.
    public let exitCode: Int32
    /// Whether the process was terminated by a signal.
    public let wasTerminated: Bool

    /// Creates a process exit.
    public init(exitCode: Int32, wasTerminated: Bool = false) {
        self.exitCode = exitCode
        self.wasTerminated = wasTerminated
    }
}

/// Manages a single child process lifecycle.
public protocol AxolotyManagedProcessRunning: Sendable {
    /// Starts the child process.
    func start(_ specification: ManagedProcessSpecification) throws
    /// Blocks until the child exits and returns its exit state.
    func waitForExit() -> ManagedProcessExit
    /// Sends SIGTERM to the child.
    func terminate()
    /// Sends SIGKILL to the child.
    func forceKill()
    /// Returns the child's PID, or nil if not started.
    var processIdentifier: Int32? { get }
    /// Whether the child process is still running.
    var isRunning: Bool { get }
}

/// Probes service readiness via TCP.
public protocol AxolotyServiceProbing: Sendable {
    /// Checks if a TCP port is available (not already bound).
    func isPortAvailable(host: String, port: UInt16) -> Bool
    /// Polls a TCP endpoint until it accepts connections or the deadline passes.
    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool
}

// MARK: - Foundation implementations

/// Foundation ``Process``-backed implementation of ``AxolotyManagedProcessRunning``.
public final class FoundationProcessRunner: AxolotyManagedProcessRunning, @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()

    public init() {}

    public func start(_ specification: ManagedProcessSpecification) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: specification.executable)
        proc.arguments = specification.arguments
        if let env = specification.environment {
            proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        try proc.run()
        lock.lock()
        process = proc
        lock.unlock()
    }

    public func waitForExit() -> ManagedProcessExit {
        lock.lock()
        let proc = process
        lock.unlock()
        guard let proc = proc else {
            return ManagedProcessExit(exitCode: -1)
        }
        proc.waitUntilExit()
        return ManagedProcessExit(
            exitCode: proc.terminationStatus,
            wasTerminated: proc.terminationReason == .uncaughtSignal
        )
    }

    public func terminate() {
        lock.lock()
        let proc = process
        lock.unlock()
        proc?.terminate()
    }

    public func forceKill() {
        lock.lock()
        let proc = process
        lock.unlock()
        if let pid = proc?.processIdentifier {
            kill(pid, SIGKILL)
        }
    }

    public var processIdentifier: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.processIdentifier
    }

    public var isRunning: Bool {
        lock.lock()
        let proc = process
        lock.unlock()
        guard let proc = proc else { return false }
        return proc.isRunning
    }
}

/// Foundation socket-backed implementation of ``AxolotyServiceProbing``.
public struct FoundationServiceProbe: AxolotyServiceProbing {
    public init() {}

    public func isPortAvailable(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, 1, 0)  // SOCK_STREAM
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    public func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if tcpConnect(host: host, port: port) {
                return true
            }
            usleep(100_000)
        }
        return false
    }

    private func tcpConnect(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, 1, 0)  // SOCK_STREAM
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Signal handling

/// A signal handler that sets a flag when SIGINT or SIGTERM is received.
public final class ServiceSignalHandler: @unchecked Sendable {
    private var interrupted = false
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []

    public init() {}

    public var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    public func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        sigint.setEventHandler { self.setInterrupted() }
        sigint.resume()
        sources.append(sigint)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
        sigterm.setEventHandler { self.setInterrupted() }
        sigterm.resume()
        sources.append(sigterm)
    }

    public func uninstall() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    private func setInterrupted() {
        lock.lock()
        interrupted = true
        lock.unlock()
    }
}

// MARK: - Temp directory provider

/// Provides temporary directories for service configuration files.
public protocol AxolotyTempDirectoryProvider: Sendable {
    /// Creates a private temporary directory and returns its path.
    func createTempDirectory() throws -> String
    /// Removes a directory at the given path.
    func removeDirectory(_ path: String)
}

/// Foundation-backed temp directory provider.
public struct FoundationTempDirectoryProvider: AxolotyTempDirectoryProvider {
    public init() {}

    public func createTempDirectory() throws -> String {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("axoloty-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        return dir.path
    }

    public func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
