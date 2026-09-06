// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses high-confidence Swift compiler, SwiftPM, and linker diagnostics
/// from captured command output.
///
/// The parser recognizes only stable forms: located source diagnostics,
/// unlocated compiler and linker errors, and compiler stack dumps. Caret and
/// source blocks following a diagnostic are preserved as emitted. Malformed
/// locations degrade to location-less diagnostics; parsing never traps.
public struct SwiftDiagnosticParser: AxolotyDiagnosticParsing {
    /// The maximum captured snippet lines per diagnostic.
    let maximumSnippetLines: Int
    /// The maximum captured stack-dump lines.
    let maximumCrashLines: Int

    /// Creates a Swift diagnostic parser.
    ///
    /// - Parameters:
    ///   - maximumSnippetLines: Maximum captured snippet lines per diagnostic.
    ///   - maximumCrashLines: Maximum captured stack-dump lines.
    public init(maximumSnippetLines: Int = 10, maximumCrashLines: Int = 40) {
        self.maximumSnippetLines = maximumSnippetLines
        self.maximumCrashLines = maximumCrashLines
    }

    /// Whether the parser applies to the command.
    ///
    /// The parser consumes every command: compiler failures surface under
    /// build, test, and arbitrary child invocations alike.
    ///
    /// - Parameter command: The completed subprocess command.
    /// - Returns: Always `true`.
    public func supports(_ command: AxolotyCommandPlan) -> Bool { true }

    /// Parses captured output into a diagnostic report.
    ///
    /// - Parameters:
    ///   - standardOutput: The complete captured standard output.
    ///   - standardError: The complete captured standard error.
    /// - Returns: The structured report, or `nil` when nothing was captured.
    public func parse(standardOutput: String, standardError: String) -> AxolotyDiagnosticReport? {
        var parsed: [AxolotyDiagnostic] = []
        var crashLines: [String]?
        var tool = AxolotyDiagnosticTool.unknown

        for stream in [standardError, standardOutput] {
            let lines = stream.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if Self.isStackDump(line) {
                    let (block, next) = Self.crashBlock(in: lines, start: index, maximumLines: maximumCrashLines)
                    crashLines = block
                    index = next
                    continue
                }
                guard let match = Self.diagnostic(from: line) else {
                    index += 1
                    continue
                }
                if tool == .unknown { tool = match.tool }
                index += 1
                let snippet = Self.snippetBlock(
                    in: lines,
                    start: &index,
                    maximumLines: maximumSnippetLines
                )
                parsed.append(AxolotyDiagnostic(
                    severity: match.diagnostic.severity,
                    message: match.diagnostic.message,
                    location: match.diagnostic.location,
                    snippet: snippet.map { AxolotySourceSnippet(text: Self.bounded($0)) }
                ))
            }
        }
        if parsed.isEmpty, crashLines == nil { return nil }
        return AxolotyDiagnosticReport(
            tool: tool,
            diagnostics: Self.attachNotes(parsed),
            compilerCrash: crashLines.map { AxolotyCompilerCrash(summary: Self.bounded($0)) }
        )
    }

    /// Attaches standalone note diagnostics to the preceding diagnostic.
    ///
    /// A note with no preceding diagnostic becomes its own diagnostic so the
    /// note is never silently dropped.
    ///
    /// - Parameter diagnostics: Parsed diagnostics in capture order.
    /// - Returns: Diagnostics with notes attached to their owners.
    static func attachNotes(_ diagnostics: [AxolotyDiagnostic]) -> [AxolotyDiagnostic] {
        var result: [AxolotyDiagnostic] = []
        for diagnostic in diagnostics {
            if diagnostic.severity == .note {
                let note = AxolotyDiagnosticNote(message: diagnostic.message, location: diagnostic.location)
                if let last = result.indices.last, result[last].severity != .note {
                    result[last] = AxolotyDiagnostic(
                        severity: result[last].severity,
                        message: result[last].message,
                        location: result[last].location,
                        snippet: result[last].snippet,
                        notes: result[last].notes + [note]
                    )
                    continue
                }
                if result.isEmpty {
                    result.append(AxolotyDiagnostic(
                        severity: .error,
                        message: diagnostic.message,
                        location: diagnostic.location
                    ))
                    continue
                }
            }
            result.append(diagnostic)
        }
        return result
    }

    private static func isStackDump(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("Stack dump:")
    }

    private static func crashBlock(
        in lines: [String],
        start: Int,
        maximumLines: Int
    ) -> (block: [String], next: Int) {
        var block = [lines[start]]
        var index = start + 1
        while index < lines.count, block.count < maximumLines {
            if diagnostic(from: lines[index]) != nil { break }
            block.append(lines[index])
            index += 1
        }
        return (block, index)
    }

    /// Captures the source or caret block associated with a diagnostic.
    ///
    /// The block ends at the next diagnostic, the next `note:` line, or the
    /// first line that is neither blank nor a recognized source/caret form.
    ///
    /// - Parameters:
    ///   - lines: All captured lines.
    ///   - start: The first line index after the diagnostic; updated to the
    ///     first unconsumed index.
    ///   - maximumLines: The maximum number of captured lines.
    /// - Returns: The captured snippet lines, or `nil` when none matched.
    static func snippetBlock(
        in lines: [String],
        start: inout Int,
        maximumLines: Int
    ) -> [String]? {
        var captured: [String] = []
        var index = start
        var allowedBlanks = 1
        while index < lines.count, captured.count < maximumLines {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                guard allowedBlanks > 0 else { break }
                allowedBlanks -= 1
                captured.append(line)
                index += 1
                continue
            }
            if trimmed.hasPrefix("note:") { break }
            if diagnostic(from: line) != nil { break }
            let isSourceOrCaretLine = line.contains("│")
                || trimmed.contains("|")
                || trimmed.contains("│")
                || line.contains(" ^")
                || line.contains("^~")
                || line.contains("~^")
                || looksLikeSourcePath(trimmed)
            if isSourceOrCaretLine {
                captured.append(line)
                index += 1
                continue
            }
            break
        }
        start = index
        guard captured.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        return captured
    }

    private static func bounded(_ lines: [String]) -> String {
        let text = lines.joined(separator: "\n")
        let maximumCharacters = 2_000
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters))
    }

    /// The parse outcome for one diagnostic line.
    struct ParsedDiagnosticLine {
        let diagnostic: AxolotyDiagnostic
        let tool: AxolotyDiagnosticTool
    }

    /// Classifies one line as a diagnostic when it matches a high-confidence
    /// form.
    ///
    /// - Parameter line: The line to classify.
    /// - Returns: The parsed diagnostic and its producing tool.
    static func diagnostic(from line: String) -> ParsedDiagnosticLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Unlocated compiler errors start the line directly.
        for severity in [AxolotyDiagnosticSeverity.error, .warning] {
            if trimmed.hasPrefix("\(severity.rawValue): ") {
                let message = String(trimmed.dropFirst("\(severity.rawValue): ".count))
                    .trimmingCharacters(in: .whitespaces)
                guard !message.isEmpty else { continue }
                return ParsedDiagnosticLine(
                    diagnostic: AxolotyDiagnostic(severity: severity, message: message),
                    tool: .swiftCompiler
                )
            }
        }
        for severity in [AxolotyDiagnosticSeverity.error, .warning, .note] {
            guard let marker = line.range(of: " \(severity.rawValue): ") else { continue }
            let prefix = String(line[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
            let message = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !message.isEmpty else { continue }
            if prefix.isEmpty {
                guard severity != .note else { continue }
                return ParsedDiagnosticLine(
                    diagnostic: AxolotyDiagnostic(severity: severity, message: message),
                    tool: .swiftCompiler
                )
            }
            if isLinkerPrefix(prefix) {
                guard severity == .error else { continue }
                return ParsedDiagnosticLine(
                    diagnostic: AxolotyDiagnostic(severity: .error, message: message),
                    tool: .linker
                )
            }
            guard looksLikeSourcePath(prefix) else { continue }
            if let location = location(from: prefix) {
                return ParsedDiagnosticLine(
                    diagnostic: AxolotyDiagnostic(
                        severity: severity,
                        message: message,
                        location: location
                    ),
                    tool: .swiftCompiler
                )
            }
            return ParsedDiagnosticLine(
                diagnostic: AxolotyDiagnostic(
                    severity: severity,
                    message: message,
                    location: AxolotySourceLocation(file: prefix, line: 0)
                ),
                tool: .swiftCompiler
            )
        }
        return nil
    }

    /// Whether a prefix names a linker tool.
    ///
    /// - Parameter prefix: The text before the severity marker.
    /// - Returns: Whether the prefix matches a known linker tool name.
    static func isLinkerPrefix(_ prefix: String) -> Bool {
        ["ld.lld", "ld64.lld", "lld", "clang", "ld:"].contains { prefix.hasPrefix($0) }
    }

    /// Whether a prefix plausibly names a source file.
    ///
    /// - Parameter prefix: The text before the severity marker.
    /// - Returns: Whether the prefix looks like a source path.
    static func looksLikeSourcePath(_ prefix: String) -> Bool {
        !prefix.isEmpty
            && (prefix.contains("/")
                || prefix.hasSuffix(".swift")
                || prefix.hasSuffix(".c")
                || prefix.hasSuffix(".cpp")
                || prefix.hasSuffix(".h")
                || prefix.hasSuffix(".m"))
    }

    /// Extracts a source location from the text before a severity marker.
    ///
    /// The marker form is `file:line[:column]: severity:`, so the prefix
    /// characteristically ends with a trailing colon, which is discarded
    /// before parsing. Paths containing spaces or colons are preserved
    /// because the split only consumes trailing line and column components.
    ///
    /// - Parameter prefix: The text before the severity marker.
    /// - Returns: The location when the trailing components parse.
    static func location(from prefix: String) -> AxolotySourceLocation? {
        guard prefix.contains(":") else { return nil }
        var parts = prefix.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, parts.last?.isEmpty == true {
            parts.removeLast()
        }
        guard parts.count >= 2 else { return nil }
        if let column = Int(parts[parts.count - 1]),
           parts.count >= 3,
           let line = Int(parts[parts.count - 2]),
           line > 0 {
            let file = parts.dropLast(2).joined(separator: ":")
            guard !file.isEmpty else { return nil }
            return AxolotySourceLocation(file: file, line: line, column: column)
        }
        if let line = Int(parts[parts.count - 1]), line > 0 {
            let file = parts.dropLast().joined(separator: ":")
            guard !file.isEmpty else { return nil }
            return AxolotySourceLocation(file: file, line: line)
        }
        return nil
    }
}
