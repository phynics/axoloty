// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The tool that produced a diagnostic report.
public enum AxolotyDiagnosticTool: String, Codable, Equatable, Sendable {
    /// The Swift compiler.
    case swiftCompiler
    /// A system linker.
    case linker
    /// An unrecognized producer.
    case unknown
}

/// Diagnostic severity, matching compiler terminology.
public enum AxolotyDiagnosticSeverity: String, Codable, Equatable, Sendable {
    /// A compilation error.
    case error
    /// A compiler warning.
    case warning
    /// A compiler note attached to another diagnostic.
    case note
}

/// A source location emitted by a tool.
public struct AxolotySourceLocation: Codable, Equatable, Hashable, Sendable {
    /// The source path as emitted by the tool.
    public let file: String
    /// The one-based line number.
    public let line: Int
    /// The one-based column number, when emitted.
    public let column: Int?

    /// Creates a source location.
    ///
    /// - Parameters:
    ///   - file: The source path as emitted by the tool.
    ///   - line: The one-based line number.
    ///   - column: The one-based column number, when emitted.
    public init(file: String, line: Int, column: Int? = nil) {
        self.file = file
        self.line = line
        self.column = column
    }
}

/// A bounded compiler-emitted source or caret block.
public struct AxolotySourceSnippet: Codable, Equatable, Sendable {
    /// The raw snippet lines, already bounded by the parser.
    public let text: String

    /// Creates a source snippet.
    ///
    /// - Parameter text: The raw snippet lines.
    public init(text: String) {
        self.text = text
    }
}

/// A note associated with a primary diagnostic.
public struct AxolotyDiagnosticNote: Codable, Equatable, Sendable {
    /// The note message.
    public let message: String
    /// The note source location, when emitted.
    public let location: AxolotySourceLocation?

    /// Creates a diagnostic note.
    ///
    /// - Parameters:
    ///   - message: The note message.
    ///   - location: The note source location, when emitted.
    public init(message: String, location: AxolotySourceLocation? = nil) {
        self.message = message
        self.location = location
    }
}

/// A bounded compiler crash section, kept separate from normal source
/// diagnostics so crash traces never masquerade as ordinary failures.
public struct AxolotyCompilerCrash: Codable, Equatable, Sendable {
    /// The bounded stack-dump section.
    public let summary: String

    /// Creates a compiler crash section.
    ///
    /// - Parameter summary: The bounded stack-dump text.
    public init(summary: String) {
        self.summary = summary
    }
}

/// One structured tool diagnostic.
public struct AxolotyDiagnostic: Codable, Equatable, Sendable {
    /// The diagnostic severity.
    public let severity: AxolotyDiagnosticSeverity
    /// The diagnostic message.
    public let message: String
    /// The source location, when the tool emitted one.
    public let location: AxolotySourceLocation?
    /// The associated source or caret block, when captured.
    public let snippet: AxolotySourceSnippet?
    /// Notes associated with the diagnostic.
    public let notes: [AxolotyDiagnosticNote]

    /// Creates a diagnostic.
    ///
    /// - Parameters:
    ///   - severity: The diagnostic severity.
    ///   - message: The diagnostic message.
    ///   - location: The source location, when emitted.
    ///   - snippet: The associated source block, when captured.
    ///   - notes: Notes associated with the diagnostic.
    public init(
        severity: AxolotyDiagnosticSeverity,
        message: String,
        location: AxolotySourceLocation? = nil,
        snippet: AxolotySourceSnippet? = nil,
        notes: [AxolotyDiagnosticNote] = []
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.snippet = snippet
        self.notes = notes
    }
}

/// A structured report over captured compiler or linker output.
public struct AxolotyDiagnosticReport: Codable, Equatable, Sendable {
    /// The tool that produced the diagnostics.
    public let tool: AxolotyDiagnosticTool
    /// The parsed diagnostics.
    public let diagnostics: [AxolotyDiagnostic]
    /// How many diagnostics were parsed but not selected for display.
    public let suppressedCount: Int
    /// The compiler crash section, when one was captured.
    public let compilerCrash: AxolotyCompilerCrash?

    /// Creates a diagnostic report.
    ///
    /// - Parameters:
    ///   - tool: The tool that produced the diagnostics.
    ///   - diagnostics: The parsed diagnostics.
    ///   - suppressedCount: How many parsed diagnostics were not selected.
    ///   - compilerCrash: The compiler crash section, when captured.
    public init(
        tool: AxolotyDiagnosticTool,
        diagnostics: [AxolotyDiagnostic],
        suppressedCount: Int = 0,
        compilerCrash: AxolotyCompilerCrash? = nil
    ) {
        self.tool = tool
        self.diagnostics = diagnostics
        self.suppressedCount = suppressedCount
        self.compilerCrash = compilerCrash
    }
}
