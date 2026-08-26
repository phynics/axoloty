// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("AxolotyCheckTests")
struct AxolotyCheckTests {}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
func node(_ name: String, dependencies: [String] = []) -> AxolotyCheckNode {
    AxolotyCheckNode(name: name, dependencies: dependencies, command: AxolotyCommandPlan(executable: name))
}

struct StubCommandRunner: AxolotyCheckCommandRunning {
    let failedCommands: Set<String>

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0,
            standardOutput: command.executable
        )
    }
}

final class CheckTestClock: AxolotyTimingClock, @unchecked Sendable {
    private(set) var value: TimeInterval

    init(_ value: TimeInterval = 0) {
        self.value = value
    }

    func now() -> TimeInterval {
        value
    }

    func advance(by seconds: TimeInterval) {
        value += seconds
    }
}

final class DeadlineRecordingRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    let clock: CheckTestClock
    let failedCommands: Set<String>
    let advancePerCommand: TimeInterval
    private(set) var commands: [AxolotyCommandPlan] = []

    init(
        clock: CheckTestClock,
        failedCommands: Set<String> = [],
        advancePerCommand: TimeInterval = 0
    ) {
        self.clock = clock
        self.failedCommands = failedCommands
        self.advancePerCommand = advancePerCommand
    }

    func run(_ command: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        commands.append(command)
        clock.advance(by: advancePerCommand)
        return AxolotyCheckCommandResult(
            exitCode: failedCommands.contains(command.executable) ? 1 : 0
        )
    }
}

final class OutputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(AxolotyCommandOutputStream, String)] = []

    func append(_ stream: AxolotyCommandOutputStream, _ text: String) {
        lock.lock()
        events.append((stream, text))
        lock.unlock()
    }

    func text(for stream: AxolotyCommandOutputStream) -> String {
        lock.lock()
        defer { lock.unlock() }
        return events.filter { $0.0 == stream }.map(\.1).joined()
    }
}

final class CommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AxolotyCheckCommandResult?

    func store(_ result: AxolotyCheckCommandResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: AxolotyCheckCommandResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
