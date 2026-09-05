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

final class ManualOverrunTask: AxolotyOverrunCancellation, @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func cancel() {
        lock.lock()
        action = nil
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = action
        self.action = nil
        lock.unlock()
        action?()
    }
}

final class ManualOverrunScheduler: AxolotyOverrunScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ManualOverrunTask] = []

    func schedule(
        after _: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> any AxolotyOverrunCancellation {
        let task = ManualOverrunTask(action: action)
        lock.lock()
        tasks.append(task)
        lock.unlock()
        return task
    }

    func fireAll() {
        lock.lock()
        let tasks = tasks
        lock.unlock()
        tasks.forEach { $0.fire() }
    }
}

final class CheckEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AxolotyCheckExecutionEvent] = []

    func append(_ event: AxolotyCheckExecutionEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [AxolotyCheckExecutionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class OverrunFiringRunner: AxolotyCheckCommandRunning, @unchecked Sendable {
    private let clock: CheckTestClock
    private let scheduler: ManualOverrunScheduler

    init(clock: CheckTestClock, scheduler: ManualOverrunScheduler) {
        self.clock = clock
        self.scheduler = scheduler
    }

    func run(_: AxolotyCommandPlan) -> AxolotyCheckCommandResult {
        clock.advance(by: 6)
        scheduler.fireAll()
        return AxolotyCheckCommandResult(
            exitCode: 0,
            observation: AxolotyCommandObservation(
                elapsedSeconds: 4,
                lastTest: "last-test",
                outputBytes: 42,
                artifactPath: "/artifacts/slow"
            )
        )
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
