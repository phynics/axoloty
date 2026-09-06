// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Parses SwiftPM and compiler build progress from subprocess output.
///
/// The parser recognizes only high-confidence, stable SwiftPM forms:
/// `[step/total]` build-plan lines and build lifecycle banners. Unknown lines
/// are ignored; raw evidence remains in the command artifacts.
public struct SwiftBuildProgressParser: AxolotyCommandProgressParsing {
    /// Creates a build progress parser.
    public init() {}

    /// Whether the parser applies to the command.
    ///
    /// Swift build steps flow through check invocations and wrapper scripts
    /// as well as direct `swift build` runs, so the parser consumes every
    /// command and simply ignores lines that carry no build step.
    ///
    /// - Parameter command: The planned subprocess command.
    /// - Returns: Always `true`.
    public func supports(_ command: AxolotyCommandPlan) -> Bool { true }

    /// Consumes one complete build output line.
    ///
    /// - Parameters:
    ///   - line: One complete logical line without its terminating newline.
    ///   - stream: The stream the line arrived on; ignored, SwiftPM uses both.
    /// - Returns: Progress for recognized `[step/total]` and banner lines.
    public mutating func consume(
        line: String,
        stream: AxolotyCommandOutputStream
    ) -> AxolotyCommandProgress? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let step = Self.stepMarker(in: text) {
            return progress(forStep: step)
        }
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("building for") {
            return AxolotyCommandProgress(phase: .planning)
        }
        if lowercased == "build complete!" || lowercased == "build complete." {
            return AxolotyCommandProgress(phase: .completed)
        }
        return nil
    }

    private func progress(forStep step: (completed: Int, total: Int, action: String)) -> AxolotyCommandProgress? {
        let action = step.action
        let counts = (completed: step.completed, total: step.total)
        if action == "Write sources" || action == "Planning build" || action == "Cloning statistics" {
            return AxolotyCommandProgress(phase: .preparing, completed: counts.completed, total: counts.total)
        }
        if action.hasPrefix("Compiling ") {
            let remainder = String(action.dropFirst("Compiling ".count))
            let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let target = parts.first.map(String.init)
            let detail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return AxolotyCommandProgress(
                phase: .compiling,
                completed: counts.completed,
                total: counts.total,
                target: target,
                detail: detail.isEmpty ? nil : detail
            )
        }
        if action.hasPrefix("Emitting module ") {
            return AxolotyCommandProgress(
                phase: .emittingModule,
                completed: counts.completed,
                total: counts.total,
                target: String(action.dropFirst("Emitting module ".count))
            )
        }
        if action.hasPrefix("Linking ") {
            return AxolotyCommandProgress(
                phase: .linking,
                completed: counts.completed,
                total: counts.total,
                target: String(action.dropFirst("Linking ".count))
            )
        }
        // A recognized counter with an unknown action still exposes bounded
        // step progress without inventing a phase.
        return AxolotyCommandProgress(phase: .running, completed: counts.completed, total: counts.total)
    }

    /// Extracts a `[completed/total] action` marker.
    ///
    /// The scanning intentionally mirrors ``AxolotyTimingOutputParser`` so
    /// step interpretation stays consistent with timing metrics.
    ///
    /// - Parameter text: The line to scan.
    /// - Returns: Completed count, total, and the action text after `]`.
    static func stepMarker(in text: String) -> (completed: Int, total: Int, action: String)? {
        guard let open = text.firstIndex(of: "["),
              let slash = text[open...].firstIndex(of: "/"),
              let close = text[slash...].firstIndex(of: "]") else { return nil }
        let completedText = text[text.index(after: open)..<slash]
        let totalText = text[text.index(after: slash)..<close]
        guard let completed = Int(completedText), let total = Int(totalText),
              completed >= 0, total > 0, completed <= total else { return nil }
        let actionStart = text.index(after: close)
        let action = text[actionStart...].trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty else { return nil }
        return (completed, total, action)
    }
}
