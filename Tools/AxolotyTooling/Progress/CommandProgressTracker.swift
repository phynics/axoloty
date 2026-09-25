// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Synchronization

/// Decides which parsed progress transitions deserve visible output.
///
/// The tracker consumes every complete output line for one command, feeds it
/// to the registered parsers, and forwards only meaningful state changes to
/// the renderer: phase or target changes, test failures, sensible progress
/// intervals, and fallback heartbeats when no parser has produced progress.
/// Rendering frequency is intentionally lower than parser frequency.
public final class AxolotyCommandProgressTracker: Sendable {
    private let node: String?
    private let stage: String
    private let commandLabel: String
    private let renderer: any AxolotyCommandProgressRendering
    private let emit: @Sendable (_ live: String, _ plain: String) -> Void
    private let now: @Sendable () -> TimeInterval
    /// Minimum seconds between rate-capped updates.
    private let minimumUpdateInterval: TimeInterval
    /// Seconds before a silent command earns a fallback status.
    private let fallbackInterval: TimeInterval

    private struct State {
        var parsers: [any AxolotyCommandProgressParsing] = []
        var lastEmitted: AxolotyCommandProgress?
        var lastEmittedAt: TimeInterval = 0
        var lastActivityAt: TimeInterval = 0
        var started = false
        var completed = false
    }
    private let state = Mutex(State())

    /// Creates a progress tracker for one command.
    ///
    /// - Parameters:
    ///   - node: The owning check node, when known.
    ///   - stage: The lifecycle stage.
    ///   - command: The planned subprocess command.
    ///   - renderer: The destination formatter.
    ///   - emit: Sink receiving the live text and the plain text recorded in
    ///     durable progress artifacts.
    ///   - now: Wall-clock seconds provider.
    ///   - minimumUpdateInterval: Minimum seconds between rate-capped updates.
    ///   - fallbackInterval: Seconds before a silent command earns a fallback.
    public init(
        node: String?,
        stage: String,
        command: AxolotyCommandPlan,
        renderer: any AxolotyCommandProgressRendering,
        emit: @escaping @Sendable (_ live: String, _ plain: String) -> Void,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        minimumUpdateInterval: TimeInterval = 0.5,
        fallbackInterval: TimeInterval = 5
    ) {
        self.node = node
        self.stage = stage
        commandLabel = Self.commandDescription(command)
        self.renderer = renderer
        self.emit = emit
        self.now = now
        self.minimumUpdateInterval = minimumUpdateInterval
        self.fallbackInterval = fallbackInterval
        state.withLock { $0.parsers = [SwiftBuildProgressParser(), SwiftTestingProgressParser()].filter { $0.supports(command) } }
    }

    /// Renders the permanent command-start header.
    public func start() {
        state.withLock { state in
            guard !state.started, !state.completed else { return }
            state.started = true
            state.lastEmittedAt = now()
            emitLine(renderer.commandStarted(node: node, stage: stage, command: commandLabel))
        }
    }

    /// Consumes one complete output line.
    ///
    /// Parsing failures never affect command semantics; an unknown line is
    /// simply ignored.
    ///
    /// - Parameters:
    ///   - line: One complete logical line without its terminating newline.
    ///   - stream: The stream the line arrived on.
    public func consumeLine(_ line: String, stream: AxolotyCommandOutputStream) {
        state.withLock { state in
            var latest: AxolotyCommandProgress?
            for index in state.parsers.indices {
                var parser = state.parsers[index]
                if let progress = parser.consume(line: line, stream: stream) { latest = progress }
                state.parsers[index] = parser
            }
            guard let latest else { return }
            state.started = true
            state.lastActivityAt = now()
            considerEmitting(latest, state: &state)
        }
    }

    /// Renders the fallback status when the command runs without parsed
    /// progress.
    ///
    /// - Parameter elapsed: Elapsed wall-clock seconds.
    public func fallback(elapsed: TimeInterval) {
        state.withLock { state in
        guard !state.completed else { return }
        state.started = true
        let timestamp = now()
        if timestamp - max(state.lastEmittedAt, state.lastActivityAt) >= fallbackInterval {
            emitLine(renderer.fallback(node: node, stage: stage, command: commandLabel, elapsed: elapsed))
            state.lastEmittedAt = timestamp
            state.lastActivityAt = timestamp
        }
        }
    }

    /// Renders the permanent command-completion line.
    ///
    /// - Parameters:
    ///   - success: Whether the command exited successfully.
    ///   - elapsed: Elapsed wall-clock seconds.
    ///   - reason: A short interruption reason, when applicable.
    public func complete(success: Bool, elapsed: TimeInterval, reason: String? = nil) {
        state.withLock { state in
            guard !state.completed else { return }
            state.completed = true
            state.started = true
            emitLine(renderer.commandCompleted(node: node, stage: stage, success: success, elapsed: elapsed, reason: reason))
        }
    }

    /// Emits permanent failure text, such as a diagnostic block, without
    /// throttling.
    ///
    /// - Parameter text: The failure text to emit.
    public func emitFailureText(_ text: String) {
        state.withLock { _ in emitLine(renderer.permanent(text)) }
    }

    /// Marks the command as finished without rendering a completion line.
    public func abandon() {
        state.withLock { $0.completed = true }
    }

    /// Every Swift Testing test name reported failed or as having recorded an
    /// issue during this command, across the whole run. Empty when the
    /// command carried no Swift Testing parser (it did not run tests) or none
    /// failed.
    public func failedTestNames() -> Set<String> {
        state.withLock { state in
        for parser in state.parsers {
            if let testing = parser as? SwiftTestingProgressParser { return testing.failedTestNames }
        }
        return []
        }
    }

    private func considerEmitting(_ progress: AxolotyCommandProgress, state: inout State) {
        let timestamp = now()
        let sinceLast = timestamp - state.lastEmittedAt
        let previous = state.lastEmitted
        state.lastEmitted = progress

        guard let previous else {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            state.lastEmittedAt = timestamp
            return
        }
        let failedIncreased = (progress.counters?.failed ?? 0) > (previous.counters?.failed ?? 0)
        let phaseChanged = progress.phase != previous.phase
        let targetChanged = progress.target != previous.target
        if phaseChanged || targetChanged || failedIncreased || progress.phase == .completed {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            state.lastEmittedAt = timestamp
            return
        }
        guard sinceLast >= minimumUpdateInterval else { return }
        if Self.crossedProgressInterval(previous: previous, current: progress)
            || progress.counters?.passed != previous.counters?.passed {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            state.lastEmittedAt = timestamp
        }
    }

    private func emitLine(_ text: String?) {
        guard let text else { return }
        let plain = Self.strippingANSI(text)
        emit(text, plain.hasSuffix("\n") ? plain : plain + "\n")
    }

    static func crossedProgressInterval(previous: AxolotyCommandProgress, current: AxolotyCommandProgress) -> Bool {
        guard let currentCompleted = current.completed, currentCompleted != previous.completed else { return false }
        guard let total = current.total, total > 0 else { return true }
        let bucket = max(1, total / 20)
        return currentCompleted / bucket != (previous.completed ?? 0) / bucket
    }

    static func commandDescription(_ command: AxolotyCommandPlan) -> String {
        let executable = URL(fileURLWithPath: command.executable).lastPathComponent
        let verb = command.arguments.first
        return verb.map { "\(executable) \($0)" } ?? executable
    }

    /// Removes terminal control sequences for durable plain-text artifacts.
    ///
    /// - Parameter text: Live text possibly containing escape sequences.
    /// - Returns: The same text without terminal control fragments.
    static func strippingANSI(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var escaped = false
        for character in text {
            if escaped {
                if character.isLetter { escaped = false }
                continue
            }
            if character == "\u{1B}" {
                escaped = true
                continue
            }
            if character == "\r" { continue }
            result.append(character)
        }
        return result
    }
}
