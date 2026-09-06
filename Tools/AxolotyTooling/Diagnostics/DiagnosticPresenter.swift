// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Formats selected diagnostics, the failure path, and the artifact pointer
/// for terminal display.
///
/// The presenter renders a diagnostic execution trace, not a runtime stack
/// trace, and only from information actually known: node, stage, command,
/// and the first primary source diagnostic.
///
/// Security: presented text derives from captured subprocess output, which
/// is intentionally unredacted while live, matching the existing raw-stream
/// behavior. Durable artifacts remain redacted by
/// ``AxolotyCommandArtifactStore``; presentation never reads source files to
/// reconstruct snippets and never widens the existing redaction model.
public enum AxolotyDiagnosticPresenter {
    /// Context describing the failing command.
    public struct Context: Sendable {
        /// The owning check node, when known.
        public let node: String?
        /// The lifecycle stage.
        public let stage: String
        /// The command label, such as `swift build`.
        public let command: String
        /// The durable command artifact directory, when known.
        public let artifactDirectory: String?

        /// Creates presentation context.
        ///
        /// - Parameters:
        ///   - node: The owning check node, when known.
        ///   - stage: The lifecycle stage.
        ///   - command: The command label.
        ///   - artifactDirectory: The durable artifact directory.
        public init(node: String?, stage: String, command: String, artifactDirectory: String?) {
            self.node = node
            self.stage = stage
            self.command = command
            self.artifactDirectory = artifactDirectory
        }
    }

    /// Formats a diagnostic report for terminal display.
    ///
    /// - Parameters:
    ///   - report: The selected diagnostic report.
    ///   - context: The failing command context.
    /// - Returns: The bounded presentation text.
    public static func present(
        _ report: AxolotyDiagnosticReport,
        context: Context
    ) -> String {
        var sections: [String] = []
        for diagnostic in report.diagnostics {
            sections.append(diagnosticSection(diagnostic))
        }
        if let crash = report.compilerCrash {
            sections.append("compiler crash:\n\(crash.summary)")
        }
        let errorCount = report.diagnostics.filter { $0.severity == .error }.count
        if errorCount > 1 {
            sections.append("\(errorCount) errors shown")
        }
        if report.suppressedCount > 0 {
            sections.append("\(report.suppressedCount) additional diagnostics omitted; see the full log")
        }
        sections.append(Self.trace(context: context, report: report))
        sections.append(Self.artifactReference(context: context))
        return sections
            .map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }
            .joined(separator: "\n\n") + "\n"
    }

    /// Formats the bounded fallback used when no diagnostics were parsed.
    ///
    /// - Parameters:
    ///   - standardError: The complete captured standard error.
    ///   - context: The failing command context.
    ///   - tailLineCount: The number of trailing lines shown.
    /// - Returns: The bounded presentation text.
    public static func presentUnparsed(
        standardError: String,
        context: Context,
        tailLineCount: Int = 15
    ) -> String {
        let lines = standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var sections: [String] = ["Unable to extract structured compiler diagnostics."]
        if !lines.isEmpty {
            let tail = lines.suffix(tailLineCount).joined(separator: "\n")
            let bounded = tail.count > 2_000 ? String(tail.suffix(2_000)) : tail
            sections.append("last output:\n\(bounded)")
        }
        sections.append(Self.trace(context: context, report: nil))
        sections.append(Self.artifactReference(context: context))
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func diagnosticSection(_ diagnostic: AxolotyDiagnostic) -> String {
        var lines: [String] = []
        if let location = diagnostic.location, location.line > 0 {
            let column = location.column.map { ":\($0)" } ?? ""
            lines.append("\(location.file):\(location.line)\(column)")
            lines.append("  \(diagnostic.severity.rawValue): \(diagnostic.message)")
        } else if let location = diagnostic.location {
            lines.append("\(location.file)")
            lines.append("  \(diagnostic.severity.rawValue): \(diagnostic.message)")
        } else {
            lines.append("\(diagnostic.severity.rawValue): \(diagnostic.message)")
        }
        if let snippet = diagnostic.snippet {
            lines.append("")
            lines.append(snippet.text)
        }
        for note in diagnostic.notes {
            if let location = note.location, location.line > 0 {
                let column = location.column.map { ":\($0)" } ?? ""
                lines.append("  note: \(note.message) (\(location.file):\(location.line)\(column))")
            } else {
                lines.append("  note: \(note.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func trace(context: Context, report: AxolotyDiagnosticReport?) -> String {
        var lines = ["trace:"]
        let path = [context.node ?? context.stage, context.stage, context.command]
        for (index, component) in path.enumerated() {
            lines.append(String(repeating: "  ", count: index) + (index == 0 ? component : "└─ \(component)"))
        }
        if let location = report?.diagnostics.first(where: { $0.severity == .error })?.location,
           location.line > 0 {
            let column = location.column.map { ":\($0)" } ?? ""
            let file = URL(fileURLWithPath: location.file).lastPathComponent
            lines.append("  └─ \(file):\(location.line)\(column)")
        }
        return lines.joined(separator: "\n")
    }

    private static func artifactReference(context: Context) -> String {
        guard let directory = context.artifactDirectory, !directory.isEmpty else {
            return "full log:\n  <artifact directory unavailable>"
        }
        return "full log:\n  \(directory)/stderr.txt"
    }
}
