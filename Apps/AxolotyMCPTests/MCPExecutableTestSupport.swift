// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum MCPExecutablePathValidationResult: Equatable {
    case accepted
    case rejected(exitCode: Int32, standardError: String)
}

internal func runMCPExecutableForPathValidation(
    arguments: [String]
) throws -> MCPExecutablePathValidationResult {
    let invocation = try makeMCPExecutableProcess(arguments: arguments)
    try invocation.start()

    guard let exitCode = waitForProcessExit(
        invocation.process,
        until: MonotonicDeadline(timeout: .milliseconds(500))
    ) else {
        _ = terminateAndReap(invocation, phase: "MCP executable path validation")
        _ = invocation.drain()
        return .accepted
    }

    let output = invocation.drain()
    return .rejected(
        exitCode: exitCode,
        standardError: output.standardError
    )
}

internal func runMCPExecutable(
    arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> (exitCode: Int32, standardError: String) {
    let invocation = try makeMCPExecutableProcess(arguments: arguments, environment: overrides)
    try invocation.start()
    let termination: MCPProcessTermination
    if let exitCode = waitForProcessExit(
        invocation.process,
        until: MonotonicDeadline(timeout: .seconds(5))
    ) {
        termination = MCPProcessTermination(
            exitCode: exitCode,
            outcome: "normal reap",
            escalated: false
        )
    } else {
        termination = terminateAndReap(invocation, phase: "MCP executable completion")
    }
    let output = invocation.drain()
    if termination.escalated {
        recordMCPProcessDiagnostic(
            phase: "MCP executable completion",
            processIdentifier: invocation.process.processIdentifier,
            termination: termination,
            output: output
        )
    }
    return (
        termination.exitCode,
        output.standardError
    )
}

private func makeMCPExecutableProcess(
    arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> MCPExecutableInvocation {
    let productsDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let executable = productsDirectory.appendingPathComponent("axoloty-mcp")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardError = standardError
    process.standardOutput = standardOutput
    var environment = ProcessInfo.processInfo.environment
    environment["AXOLOTY_MQTT_PORT"] = "1883"
    environment["AXOLOTY_MCP_PORT"] = String(try freeLoopbackPort())
    for (name, value) in overrides {
        environment[name] = value
    }
    process.environment = environment

    return MCPExecutableInvocation(
        process: process,
        standardOutput: standardOutput,
        standardError: standardError
    )
}

private struct MonotonicDeadline: Sendable {
    private let uptimeNanoseconds: UInt64

    init(timeout: Duration) {
        let components = timeout.components
        let seconds = components.seconds > 0 ? UInt64(components.seconds) : 0
        let attoseconds = components.attoseconds > 0 ? UInt64(components.attoseconds) : 0
        let durationNanoseconds = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let extraNanoseconds = attoseconds / 1_000_000_000
        let totalNanoseconds: UInt64
        if durationNanoseconds.overflow {
            totalNanoseconds = UInt64.max
        } else {
            totalNanoseconds = durationNanoseconds.partialValue.addingReportingOverflow(extraNanoseconds).overflow
                ? UInt64.max
                : durationNanoseconds.partialValue + extraNanoseconds
        }
        let now = DispatchTime.now().uptimeNanoseconds
        uptimeNanoseconds = now.addingReportingOverflow(totalNanoseconds).overflow
            ? UInt64.max
            : now + totalNanoseconds
    }

    var isExpired: Bool {
        DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds
    }

    var dispatchTime: DispatchTime {
        DispatchTime(uptimeNanoseconds: uptimeNanoseconds)
    }
}

private struct MCPExecutableOutput {
    let standardOutput: String
    let standardError: String
}

private struct MCPProcessTermination {
    let exitCode: Int32
    let outcome: String
    let escalated: Bool
}

private final class MCPExecutableOutputDrain: @unchecked Sendable {
    private let standardOutput: Pipe
    private let standardError: Pipe
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var outputData = Data()
    private var errorData = Data()

    init(standardOutput: Pipe, standardError: Pipe) {
        self.standardOutput = standardOutput
        self.standardError = standardError

        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            read(standardOutput.fileHandleForReading, isError: false)
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            read(standardError.fileHandleForReading, isError: true)
        }
    }

    private func read(_ handle: FileHandle, isError: Bool) {
        defer { group.leave() }
        while true {
            let data = handle.readData(ofLength: 16 * 1024)
            guard !data.isEmpty else { return }
            lock.lock()
            if isError {
                errorData.append(data)
            } else {
                outputData.append(data)
            }
            lock.unlock()
        }
    }

    func wait(until deadline: MonotonicDeadline) -> Bool {
        group.wait(timeout: deadline.dispatchTime) == .success
    }

    func close() {
        standardOutput.fileHandleForReading.closeFile()
        standardError.fileHandleForReading.closeFile()
    }

    func output() -> MCPExecutableOutput {
        lock.lock()
        defer { lock.unlock() }
        return MCPExecutableOutput(
            standardOutput: String(bytes: outputData, encoding: .utf8) ?? "",
            standardError: String(bytes: errorData, encoding: .utf8) ?? ""
        )
    }
}

private struct MCPExecutableInvocation {
    let process: Process
    let standardOutput: Pipe
    let standardError: Pipe
    private let outputDrain: MCPExecutableOutputDrain

    init(process: Process, standardOutput: Pipe, standardError: Pipe) {
        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
        outputDrain = MCPExecutableOutputDrain(
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    func start() throws {
        do {
            try process.run()
        } catch {
            outputDrain.close()
            throw error
        }
    }

    func drain() -> MCPExecutableOutput {
        let deadline = MonotonicDeadline(timeout: .seconds(1))
        if !outputDrain.wait(until: deadline) {
            outputDrain.close()
            _ = outputDrain.wait(until: MonotonicDeadline(timeout: .milliseconds(100)))
        }
        return outputDrain.output()
    }

    func stopOutputDrain() {
        outputDrain.close()
    }
}

private func waitForProcessExit(
    _ process: Process,
    until deadline: MonotonicDeadline
) -> Int32? {
    let processIdentifier = process.processIdentifier
    while !deadline.isExpired {
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
            return processExitCode(from: status)
        }
        if result < 0 {
            #if canImport(Glibc)
            if Glibc.errno == ECHILD { return process.terminationStatus }
            #elseif canImport(Darwin)
            if Darwin.errno == ECHILD { return process.terminationStatus }
            #endif
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return nil
}

private func terminateAndReap(
    _ invocation: MCPExecutableInvocation,
    phase: String
) -> MCPProcessTermination {
    let processIdentifier = invocation.process.processIdentifier
    if let exitCode = waitForProcessExit(
        invocation.process,
        until: MonotonicDeadline(timeout: .milliseconds(100))
    ) {
        return MCPProcessTermination(
            exitCode: exitCode,
            outcome: "already exited before termination",
            escalated: false
        )
    }

    invocation.process.terminate()
    if let exitCode = waitForProcessExit(
        invocation.process,
        until: MonotonicDeadline(timeout: .seconds(1))
    ) {
        return MCPProcessTermination(
            exitCode: exitCode,
            outcome: "TERM and reap succeeded",
            escalated: true
        )
    }

    _ = kill(processIdentifier, SIGKILL)
    if let exitCode = waitForProcessExit(
        invocation.process,
        until: MonotonicDeadline(timeout: .seconds(1))
    ) {
        return MCPProcessTermination(
            exitCode: exitCode,
            outcome: "KILL and reap succeeded",
            escalated: true
        )
    }

    invocation.stopOutputDrain()
    return MCPProcessTermination(
        exitCode: 137,
        outcome: "TERM → KILL → reap deadline exceeded",
        escalated: true
    )
}

private func recordMCPProcessDiagnostic(
    phase: String,
    processIdentifier: Int32,
    termination: MCPProcessTermination,
    output: MCPExecutableOutput
) {
    let standardOutputTail = boundedOutputTail(output.standardOutput)
    let standardErrorTail = boundedOutputTail(output.standardError)
    Issue.record(
        "MCP process phase='\(phase)' pid=\(processIdentifier) exit=\(termination.exitCode) outcome='\(termination.outcome)' stdout_tail=\(standardOutputTail) stderr_tail=\(standardErrorTail)"
    )
}

private func boundedOutputTail(_ output: String, maximumBytes: Int = 512) -> String {
    let bytes = Data(output.utf8)
    return String(bytes: bytes.suffix(maximumBytes), encoding: .utf8) ?? ""
}

private func processExitCode(from status: Int32) -> Int32 {
    if status & 0x7f == 0 {
        return (status >> 8) & 0xff
    }
    return 128 + (status & 0x7f)
}

private func freeLoopbackPort() throws -> UInt16 {
    let descriptor = socket(AF_INET, 1, 0) // SOCK_STREAM
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { close(descriptor) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        throw CocoaError(.fileReadUnknown)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw CocoaError(.fileWriteUnknown) }

    var boundAddress = sockaddr_in()
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(descriptor, socketAddress, &addressLength)
        }
    }
    guard nameResult == 0 else { throw CocoaError(.fileReadUnknown) }
    return UInt16(bigEndian: boundAddress.sin_port)
}
