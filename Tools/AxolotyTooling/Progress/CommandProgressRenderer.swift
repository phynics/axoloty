// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Formats progress state transitions for one output destination.
///
/// Renderers own presentation only. Parsing stays in progress parsers and
/// throttling stays in ``AxolotyCommandProgressTracker``.
public protocol AxolotyCommandProgressRendering: AnyObject, Sendable {
    /// Formats the permanent line shown when a command starts.
    ///
    /// - Parameters:
    ///   - node: The owning check node, when known.
    ///   - stage: The lifecycle stage.
    ///   - command: A short command label.
    /// - Returns: Rendered text, or `nil` to stay silent.
    func commandStarted(node: String?, stage: String, command: String) -> String?

    /// Formats a meaningful progress update.
    ///
    /// - Parameters:
    ///   - progress: The parsed progress state.
    ///   - node: The owning check node, when known.
    ///   - stage: The lifecycle stage.
    ///   - elapsed: Elapsed wall-clock seconds.
    /// - Returns: Rendered text, or `nil` to stay silent.
    func progress(
        _ progress: AxolotyCommandProgress,
        node: String?,
        stage: String,
        elapsed: TimeInterval
    ) -> String?

    /// Formats a fallback status used when no parser produced progress.
    ///
    /// - Parameters:
    ///   - node: The owning check node, when known.
    ///   - stage: The lifecycle stage.
    ///   - command: A short command label.
    ///   - elapsed: Elapsed wall-clock seconds.
    /// - Returns: Rendered text, or `nil` to stay silent.
    func fallback(
        node: String?,
        stage: String,
        command: String,
        elapsed: TimeInterval
    ) -> String?

    /// Formats the permanent line shown when a command completes.
    ///
    /// - Parameters:
    ///   - node: The owning check node, when known.
    ///   - stage: The lifecycle stage.
    ///   - success: Whether the command exited successfully.
    ///   - elapsed: Elapsed wall-clock seconds.
    ///   - reason: A short interruption reason, when the command did not
    ///     complete on its own.
    /// - Returns: Rendered text, or `nil` to stay silent.
    func commandCompleted(
        node: String?,
        stage: String,
        success: Bool,
        elapsed: TimeInterval,
        reason: String?
    ) -> String?

    /// Formats permanent failure text, such as a diagnostic block.
    ///
    /// - Parameter text: The failure text to emit.
    /// - Returns: Rendered text, or `nil` to stay silent.
    func permanent(_ text: String) -> String?
}

/// Renders append-only progress lines for non-interactive destinations such
/// as CI logs. The renderer never emits ANSI control sequences.
public final class AxolotyContinuousProgressRenderer: AxolotyCommandProgressRendering, @unchecked Sendable {
    /// Creates a continuous, append-only progress renderer.
    public init() {}

    /// Appends a start record.
    public func commandStarted(node: String?, stage: String, command: String) -> String? {
        Self.ensureTrailingNewline("[\(Self.label(node: node, stage: stage))] \(command) started")
    }

    /// Appends a bounded progress record.
    public func progress(
        _ progress: AxolotyCommandProgress,
        node: String?,
        stage: String,
        elapsed: TimeInterval
    ) -> String? {
        var text = "[\(Self.label(node: node, stage: stage))] \(Self.verb(progress.phase))"
        if let target = progress.target { text += " \(target)" }
        if let completed = progress.completed {
            text += " \(completed)"
            if let total = progress.total { text += "/\(total)" }
        }
        return Self.ensureTrailingNewline(text)
    }

    /// Appends a fallback record for long silent stretches.
    public func fallback(
        node: String?,
        stage: String,
        command: String,
        elapsed: TimeInterval
    ) -> String? {
        Self.ensureTrailingNewline("[\(Self.label(node: node, stage: stage))] still running \(Self.duration(elapsed))")
    }

    /// Appends a completion record.
    public func commandCompleted(
        node: String?,
        stage: String,
        success: Bool,
        elapsed: TimeInterval,
        reason: String?
    ) -> String? {
        let outcome = success ? "passed" : "failed"
        var text = "[\(Self.label(node: node, stage: stage))] \(outcome) \(Self.duration(elapsed))"
        if let reason { text += " (\(reason))" }
        return Self.ensureTrailingNewline(text)
    }

    /// Emits permanent failure text unchanged.
    public func permanent(_ text: String) -> String? {
        Self.ensureTrailingNewline(text)
    }

    static func label(node: String?, stage: String) -> String {
        node ?? stage
    }

    static func duration(_ elapsed: TimeInterval) -> String {
        String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), elapsed)
    }

    static func ensureTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    static func verb(_ phase: AxolotyCommandPhase?) -> String {
        switch phase {
        case .preparing: "preparing"
        case .resolving: "resolving"
        case .planning: "planning"
        case .compiling: "compiling"
        case .emittingModule: "emitting"
        case .linking: "linking"
        case .testing: "testing"
        case .startingService: "starting"
        case .waiting: "waiting"
        case .running: "running"
        case .completed: "completed"
        case nil: "running"
        }
    }
}

/// Renders in-place status output for interactive terminals.
///
/// Only the active status line is mutable; permanent transitions are printed
/// once. The renderer degrades by design when the destination is not a
/// terminal: every mutable update begins with a carriage return and a clear
/// escape, so a redirected capture shows flat lines instead of fragments.
public final class AxolotyInteractiveProgressRenderer: AxolotyCommandProgressRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var hasActiveStatus = false

    /// Creates an interactive progress renderer.
    public init() {}

    /// Prints the permanent node header.
    public func commandStarted(node: String?, stage: String, command: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.ensureTrailingNewline("● \(Self.label(node: node, stage: stage)) \(command)")
    }

    /// Overwrites the active status line in place.
    public func progress(
        _ progress: AxolotyCommandProgress,
        node: String?,
        stage: String,
        elapsed: TimeInterval
    ) -> String? {
        var text = "  \(Self.verb(progress.phase))"
        if let target = progress.target { text += " \(target)" }
        if let completed = progress.completed {
            text += "  [\(completed)"
            if let total = progress.total { text += "/\(total)" }
            text += "]"
        }
        if let detail = progress.detail { text += "  \(detail)" }
        return active(text)
    }

    /// Overwrites the active status line with a fallback status.
    public func fallback(
        node: String?,
        stage: String,
        command: String,
        elapsed: TimeInterval
    ) -> String? {
        active("  \(command)  \(Self.duration(elapsed))  (still running)")
    }

    /// Clears the status line and prints the permanent completion line.
    public func commandCompleted(
        node: String?,
        stage: String,
        success: Bool,
        elapsed: TimeInterval,
        reason: String?
    ) -> String? {
        let symbol = success ? "✓" : "✗"
        var text = "\(symbol) \(Self.label(node: node, stage: stage)) \(Self.duration(elapsed))"
        if let reason { text += " (\(reason))" }
        return clearActive() + Self.ensureTrailingNewline(text)
    }

    /// Prints permanent failure text after clearing the status line.
    public func permanent(_ text: String) -> String? {
        clearActive() + Self.ensureTrailingNewline(text)
    }

    private func clearActive() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard hasActiveStatus else { return "" }
        hasActiveStatus = false
        return "\r\u{1B}[2K"
    }

    private func active(_ text: String) -> String {
        lock.lock()
        hasActiveStatus = true
        lock.unlock()
        return "\r\u{1B}[2K\(text)"
    }

    static func label(node: String?, stage: String) -> String {
        node ?? stage
    }

    static func duration(_ elapsed: TimeInterval) -> String {
        String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), elapsed)
    }

    static func ensureTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }

    static func verb(_ phase: AxolotyCommandPhase?) -> String {
        switch phase {
        case .preparing: "Planning build"
        case .resolving: "Resolving dependencies"
        case .planning: "Planning build"
        case .compiling: "Compiling"
        case .emittingModule: "Emitting"
        case .linking: "Linking"
        case .testing: "Running tests"
        case .startingService: "Starting"
        case .waiting: "Waiting"
        case .running: "Running"
        case .completed: "Completing"
        case nil: "Running"
        }
    }
}
