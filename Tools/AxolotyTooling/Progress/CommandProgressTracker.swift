// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Decides which parsed progress transitions deserve visible output.
///
/// The tracker consumes every complete output line for one command, feeds it
/// to the registered parsers, and forwards only meaningful state changes to
/// the renderer: phase or target changes, test failures, sensible progress
/// intervals, and fallback heartbeats when no parser has produced progress.
/// Rendering frequency is intentionally lower than parser frequency.
public final class AxolotyCommandProgressTracker: @unchecked Sendable {
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

    private let lock = NSLock()
    private var parsers: [any AxolotyCommandProgressParsing] = []
    private var lastEmitted: AxolotyCommandProgress?
    private var lastEmittedAt: TimeInterval = 0
    private var lastActivityAt: TimeInterval = 0
    private var started = false
    private var completed = false

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
        parsers = [SwiftBuildProgressParser(), SwiftTestingProgressParser()]
            .filter { $0.supports(command) }
    }

    /// Renders the permanent command-start header.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !completed else { return }
        started = true
        lastEmittedAt = now()
        emitLine(renderer.commandStarted(node: node, stage: stage, command: commandLabel))
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
        var latest: AxolotyCommandProgress?
        for index in parsers.indices {
            var parser = parsers[index]
            if let progress = parser.consume(line: line, stream: stream) {
                latest = progress
            }
            parsers[index] = parser
        }
        guard let latest else { return }
        lock.lock()
        defer { lock.unlock() }
        started = true
        lastActivityAt = now()
        considerEmitting(latest)
    }

    /// Renders the fallback status when the command runs without parsed
    /// progress.
    ///
    /// - Parameter elapsed: Elapsed wall-clock seconds.
    public func fallback(elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        started = true
        let timestamp = now()
        if timestamp - max(lastEmittedAt, lastActivityAt) >= fallbackInterval {
            emitLine(renderer.fallback(node: node, stage: stage, command: commandLabel, elapsed: elapsed))
            lastEmittedAt = timestamp
            lastActivityAt = timestamp
        }
    }

    /// Renders the permanent command-completion line.
    ///
    /// - Parameters:
    ///   - success: Whether the command exited successfully.
    ///   - elapsed: Elapsed wall-clock seconds.
    ///   - reason: A short interruption reason, when applicable.
    public func complete(success: Bool, elapsed: TimeInterval, reason: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        started = true
        emitLine(renderer.commandCompleted(node: node, stage: stage, success: success, elapsed: elapsed, reason: reason))
    }

    /// Emits permanent failure text, such as a diagnostic block, without
    /// throttling.
    ///
    /// - Parameter text: The failure text to emit.
    public func emitFailureText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        emitLine(renderer.permanent(text))
    }

    /// Marks the command as finished without rendering a completion line.
    public func abandon() {
        lock.lock()
        defer { lock.unlock() }
        completed = true
    }

    /// Every Swift Testing test name reported failed or as having recorded an
    /// issue during this command, across the whole run. Empty when the
    /// command carried no Swift Testing parser (it did not run tests) or none
    /// failed.
    public func failedTestNames() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        for parser in parsers {
            if let testing = parser as? SwiftTestingProgressParser { return testing.failedTestNames }
        }
        return []
    }

    private func considerEmitting(_ progress: AxolotyCommandProgress) {
        let timestamp = now()
        let sinceLast = timestamp - lastEmittedAt
        let previous = lastEmitted
        lastEmitted = progress

        guard let previous else {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            lastEmittedAt = timestamp
            return
        }
        let failedIncreased = (progress.counters?.failed ?? 0) > (previous.counters?.failed ?? 0)
        let phaseChanged = progress.phase != previous.phase
        let targetChanged = progress.target != previous.target
        if phaseChanged || targetChanged || failedIncreased || progress.phase == .completed {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            lastEmittedAt = timestamp
            return
        }
        guard sinceLast >= minimumUpdateInterval else { return }
        if Self.crossedProgressInterval(previous: previous, current: progress)
            || progress.counters?.passed != previous.counters?.passed {
            emitLine(renderer.progress(progress, node: node, stage: stage, elapsed: 0))
            lastEmittedAt = timestamp
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
