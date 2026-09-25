// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization
import AxolotyProcessLauncher
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

/// Describes one process that did not complete the bounded shutdown policy.
public struct ManagedProcessCleanupFailure: Sendable, Equatable {
    /// The process identifier, when the runner supplied one.
    public let processIdentifier: Int32?
    /// A redacted executable and argument summary.
    public let processDescription: String
    /// The final cleanup phase.
    public let phase: String

    /// Creates a cleanup failure.
    public init(processIdentifier: Int32?, processDescription: String, phase: String) {
        self.processIdentifier = processIdentifier
        self.processDescription = processDescription
        self.phase = phase
    }
}

/// The result of a supervisor shutdown attempt.
public struct ManagedProcessCleanupReport: Sendable, Equatable {
    /// Processes that remained unreaped after escalation.
    public let failures: [ManagedProcessCleanupFailure]

    /// Creates a cleanup report.
    public init(failures: [ManagedProcessCleanupFailure] = []) {
        self.failures = failures
    }
}

/// Manages a single child process lifecycle.
public protocol AxolotyManagedProcessRunning: Sendable {
    /// Starts the child process.
    func start(_ specification: ManagedProcessSpecification) throws
    /// Blocks until the child exits and returns its exit state.
    /// Waits for exit for at most the supplied number of seconds.
    ///
    /// - Parameter timeoutSeconds: The maximum blocking duration.
    /// - Returns: The exit state, or `nil` when the process was not reaped.
    func waitForExit(timeoutSeconds: TimeInterval) -> ManagedProcessExit?
    /// Sends SIGTERM to the child.
    func terminate()
    /// Sends SIGKILL to the child.
    func forceKill()
    /// Returns the child's PID, or nil if not started.
    var processIdentifier: Int32? { get }
    /// A redacted description used in cleanup diagnostics.
    var processDescription: String { get }
    /// Whether the child process is still running.
    var isRunning: Bool { get }
}

/// Coordinates shutdown of the child processes owned by one service runner.
final class ManagedProcessSupervisor: Sendable {
    private let shutdownTimeout: TimeInterval
    private struct State: Sendable {
        var runners: [any AxolotyManagedProcessRunning] = []
        var stopping = false
    }
    private let state = Mutex(State())
    private let shutdownLock = Mutex(())

    init(shutdownTimeout: TimeInterval = 5.0, reapTimeout: TimeInterval = 2.0) {
        self.shutdownTimeout = shutdownTimeout
        self.reapTimeout = reapTimeout
    }

    private let reapTimeout: TimeInterval

    func register(_ runner: any AxolotyManagedProcessRunning) {
        let shouldTerminate = state.withLock { state -> Bool in
            state.runners.append(runner)
            return state.stopping
        }

        if shouldTerminate {
            runner.terminate()
        }
    }

    func requestTermination() {
        let activeRunners = markStoppingAndSnapshot()
        for runner in activeRunners where runner.isRunning {
            runner.terminate()
        }
    }

    func terminateAndWait() -> ManagedProcessCleanupReport {
        shutdownLock.withLock { _ in

        let activeRunners = markStoppingAndSnapshot()
        for runner in activeRunners where runner.isRunning {
            runner.terminate()
        }

        let deadline = Date().addingTimeInterval(shutdownTimeout)
        while Date() < deadline {
            if activeRunners.allSatisfy({ !$0.isRunning }) {
                break
            }
            usleep(50_000)
        }

        for runner in activeRunners where runner.isRunning {
            runner.forceKill()
        }

        var failures: [ManagedProcessCleanupFailure] = []
        let reapDeadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, reapTimeout) * 1_000_000_000)
        for runner in activeRunners {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = now >= reapDeadline
                ? 0
                : Double(reapDeadline - now) / 1_000_000_000
            guard runner.waitForExit(timeoutSeconds: remaining) != nil else {
                failures.append(
                    ManagedProcessCleanupFailure(
                        processIdentifier: runner.processIdentifier,
                        processDescription: runner.processDescription,
                        phase: "reap-timeout"
                    )
                )
                continue
            }
        }
        return ManagedProcessCleanupReport(failures: failures)
        }
    }

    private func markStoppingAndSnapshot() -> [any AxolotyManagedProcessRunning] {
        state.withLock { state in
            state.stopping = true
            return state.runners
        }
    }
}

/// Probes service readiness via TCP.
public protocol AxolotyServiceProbing: Sendable {
    /// Checks if a TCP port is available (not already bound).
    func isPortAvailable(host: String, port: UInt16) -> Bool
    /// Polls a TCP endpoint until it accepts connections or the deadline passes.
    func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool
}

// MARK: - Foundation implementations

func urlAuthorityHost(_ host: String) -> String {
    host.contains(":") ? "[\(host)]" : host
}

/// Foundation ``Process``-backed implementation of ``AxolotyManagedProcessRunning``.
// @unchecked: Foundation Process is non-Sendable; its reference is published and read under this mutex.
public final class FoundationProcessRunner: AxolotyManagedProcessRunning, @unchecked Sendable {
    private let processState = Mutex<Process?>(nil)

    public init() {}

    public func start(_ specification: ManagedProcessSpecification) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: specification.executable)
        proc.arguments = specification.arguments
        if let env = specification.environment {
            proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        try proc.run()
        processState.withLock { $0 = proc }
    }

    public func waitForExit(timeoutSeconds: TimeInterval) -> ManagedProcessExit? {
        let proc = processState.withLock { $0 }
        guard let proc = proc else {
            return ManagedProcessExit(exitCode: -1)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        while proc.isRunning {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                return nil
            }
            usleep(10_000)
        }
        return ManagedProcessExit(
            exitCode: proc.terminationStatus,
            wasTerminated: proc.terminationReason == .uncaughtSignal
        )
    }

    public var processDescription: String {
        processState.withLock { process in
            guard let process else { return "unstarted process" }
            return process.executableURL?.path ?? "managed process"
        }
    }

    public func terminate() {
        let proc = processState.withLock { $0 }
        proc?.terminate()
    }

    public func forceKill() {
        let proc = processState.withLock { $0 }
        if let pid = proc?.processIdentifier {
            kill(pid, SIGKILL)
        }
    }

    public var processIdentifier: Int32? {
        processState.withLock { $0?.processIdentifier }
    }

    public var isRunning: Bool {
        let proc = processState.withLock { $0 }
        guard let proc = proc else { return false }
        return proc.isRunning
    }
}

/// Foundation socket-backed implementation of ``AxolotyServiceProbing``.
public struct FoundationServiceProbe: AxolotyServiceProbing {
    public init() {}

    public func isPortAvailable(host: String, port: UInt16) -> Bool {
        withResolvedAddresses(host: host, port: port) { info in
            var current: UnsafeMutablePointer<addrinfo>? = info
            while let address = current {
                let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
                if fd >= 0 {
                    defer { close(fd) }
                    var reuse: Int32 = 1
                    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
                    if bind(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                        return true
                    }
                }
                current = address.pointee.ai_next
            }
            return false
        }
    }

    public func waitForTCP(host: String, port: UInt16, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        return withResolvedAddresses(host: host, port: port) { info in
            while Date() < deadline {
                var current: UnsafeMutablePointer<addrinfo>? = info
                while let address = current {
                    let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
                    if fd >= 0 {
                        defer { close(fd) }
                        if connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 {
                            return true
                        }
                    }
                    current = address.pointee.ai_next
                }
                usleep(100_000)
            }
            return false
        }
    }

    private func withResolvedAddresses(
        host: String,
        port: UInt16,
        _ body: (UnsafeMutablePointer<addrinfo>) -> Bool
    ) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = 1 // SOCK_STREAM
        var results: UnsafeMutablePointer<addrinfo>?
        let service = String(port)
        let resolutionResult = host.withCString { hostPointer in
            service.withCString { servicePointer in
                getaddrinfo(hostPointer, servicePointer, &hints, &results)
            }
        }
        guard resolutionResult == 0, let results else {
            return false
        }
        defer { freeaddrinfo(results) }
        return body(results)
    }
}

// MARK: - Signal handling

protocol ServiceSignalHandling: Sendable {
    var isInterrupted: Bool { get }
    func install()
    func uninstall()
}

protocol ServiceSignalHandlerFactory: Sendable {
    func makeHandler(onInterrupt: @escaping @Sendable () -> Void) -> any ServiceSignalHandling
}

/// A signal handler that records and reports SIGINT or SIGTERM interruptions.
// @unchecked: signal sources and saved POSIX disposition pointers live behind this mutex.
public final class ServiceSignalHandler: ServiceSignalHandling, @unchecked Sendable {
    private struct State {
        var interrupted = false
        var sources: [DispatchSourceSignal] = []
        var savedDispositions: (int: UnsafeMutableRawPointer?, term: UnsafeMutableRawPointer?)?
    }
    private let state = Mutex(State())
    private let onInterrupt: (@Sendable () -> Void)?

    /// Creates a signal handler.
    ///
    /// - Parameter onInterrupt: An optional callback invoked once after the first
    ///   SIGINT or SIGTERM is received.
    public init(onInterrupt: (@Sendable () -> Void)? = nil) {
        self.onInterrupt = onInterrupt
    }

    public var isInterrupted: Bool {
        state.withLock { $0.interrupted }
    }

    public func install() {
        state.withLock { state in
        guard state.sources.isEmpty else { return }
        state.savedDispositions = (
            axoloty_capture_signal_disposition(SIGINT),
            axoloty_capture_signal_disposition(SIGTERM)
        )
        _ = axoloty_ignore_signal(SIGINT)
        _ = axoloty_ignore_signal(SIGTERM)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
        sigint.setEventHandler { self.setInterrupted() }
        sigint.resume()
        state.sources.append(sigint)

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
        sigterm.setEventHandler { self.setInterrupted() }
        sigterm.resume()
        state.sources.append(sigterm)
        }
    }

    public func uninstall() {
        let (currentSources, savedDispositions) = state.withLock { state in
            let currentSources = state.sources
            state.sources.removeAll()
            let savedDispositions = state.savedDispositions
            state.savedDispositions = nil
            return (currentSources, savedDispositions)
        }
        currentSources.forEach { $0.cancel() }
        if let savedDispositions {
            _ = axoloty_restore_signal_disposition(SIGINT, savedDispositions.int)
            _ = axoloty_restore_signal_disposition(SIGTERM, savedDispositions.term)
            axoloty_release_signal_disposition(savedDispositions.int)
            axoloty_release_signal_disposition(savedDispositions.term)
        }
    }

    private func setInterrupted() {
        let shouldNotify = state.withLock { state -> Bool in
            let shouldNotify = !state.interrupted
            state.interrupted = true
            return shouldNotify
        }

        if shouldNotify {
            onInterrupt?()
        }
    }
}

struct DefaultServiceSignalHandlerFactory: ServiceSignalHandlerFactory {
    func makeHandler(onInterrupt: @escaping @Sendable () -> Void) -> any ServiceSignalHandling {
        ServiceSignalHandler(onInterrupt: onInterrupt)
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
