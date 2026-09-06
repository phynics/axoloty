// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// An incremental, line-oriented parser that turns subprocess output into
/// progress.
///
/// Parsers are advisory: malformed input must never change command exit
/// status, timeout behavior, cancellation behavior, or artifact capture.
/// Parser state is scoped to a single command; parsers must not keep global
/// state and must not write to the terminal.
public protocol AxolotyCommandProgressParsing: Sendable {
    /// Whether this parser applies to the given command plan.
    ///
    /// - Parameter command: The planned subprocess command.
    /// - Returns: Whether the parser should consume the command's lines.
    func supports(_ command: AxolotyCommandPlan) -> Bool

    /// Consumes one complete output line.
    ///
    /// - Parameters:
    ///   - line: One complete logical line without its terminating newline.
    ///   - stream: The stream the line arrived on.
    /// - Returns: Progress when the line carried a recognized state change,
    ///   or `nil` when the line should be ignored.
    mutating func consume(
        line: String,
        stream: AxolotyCommandOutputStream
    ) -> AxolotyCommandProgress?
}
