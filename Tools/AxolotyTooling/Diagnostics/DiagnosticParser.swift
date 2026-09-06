// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A post-completion parser that turns captured tool output into a
/// structured diagnostic report.
///
/// Diagnostic parsing is a post-completion operation; it never runs
/// synchronously per emitted line and never changes command semantics.
public protocol AxolotyDiagnosticParsing: Sendable {
    /// Whether this parser applies to the given command plan.
    ///
    /// - Parameter command: The completed subprocess command.
    /// - Returns: Whether the parser should analyze the captured output.
    func supports(_ command: AxolotyCommandPlan) -> Bool

    /// Parses captured output into a diagnostic report.
    ///
    /// - Parameters:
    ///   - standardOutput: The complete captured standard output.
    ///   - standardError: The complete captured standard error.
    /// - Returns: The structured report, or `nil` when nothing was captured.
    func parse(standardOutput: String, standardError: String) -> AxolotyDiagnosticReport?
}
