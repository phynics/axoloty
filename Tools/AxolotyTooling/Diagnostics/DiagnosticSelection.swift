// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Conservative selection over parsed diagnostics for terminal display.
///
/// Selection always keeps the first primary error, preserves notes attached
/// to shown diagnostics, deduplicates exact duplicates, and reports how many
/// parsed diagnostics were omitted. The raw artifact remains authoritative
/// for anything omitted.
public enum AxolotyDiagnosticSelection {
    /// The default maximum number of primary errors shown.
    public static let defaultMaximumErrors = 8
    /// The default maximum number of warnings shown.
    public static let defaultMaximumWarnings = 3
    /// The default maximum number of notes shown per diagnostic.
    public static let defaultMaximumNotesPerDiagnostic = 5

    /// Applies selection limits to a parsed report.
    ///
    /// - Parameters:
    ///   - report: The parsed report.
    ///   - maximumErrors: The maximum number of errors shown.
    ///   - maximumWarnings: The maximum number of warnings shown.
    ///   - maximumNotesPerDiagnostic: The maximum notes kept per diagnostic.
    /// - Returns: A report bounded to the limits, with an accurate
    ///   suppressed count.
    public static func apply(
        _ report: AxolotyDiagnosticReport,
        maximumErrors: Int = defaultMaximumErrors,
        maximumWarnings: Int = defaultMaximumWarnings,
        maximumNotesPerDiagnostic: Int = defaultMaximumNotesPerDiagnostic
    ) -> AxolotyDiagnosticReport {
        var seen = Set<DeduplicationKey>()
        var selected: [AxolotyDiagnostic] = []
        var errorsShown = 0
        var warningsShown = 0
        var suppressed = 0

        for diagnostic in report.diagnostics {
            let notes = Array(diagnostic.notes.prefix(maximumNotesPerDiagnostic))
            let bounded = AxolotyDiagnostic(
                severity: diagnostic.severity,
                message: diagnostic.message,
                location: diagnostic.location,
                snippet: diagnostic.snippet,
                notes: notes
            )
            if notes.count < diagnostic.notes.count {
                suppressed += diagnostic.notes.count - notes.count
            }
            let key = DeduplicationKey(diagnostic: bounded)
            if seen.contains(key) {
                suppressed += 1
                continue
            }
            switch diagnostic.severity {
            case .error:
                if errorsShown >= maximumErrors {
                    suppressed += 1
                    continue
                }
                errorsShown += 1
            case .warning:
                if warningsShown >= maximumWarnings {
                    suppressed += 1
                    continue
                }
                warningsShown += 1
            case .note:
                // Standalone notes are never selected for display; they only
                // appear attached to a shown diagnostic.
                suppressed += 1
                continue
            }
            seen.insert(key)
            selected.append(bounded)
        }
        return AxolotyDiagnosticReport(
            tool: report.tool,
            diagnostics: selected,
            suppressedCount: report.suppressedCount + suppressed,
            compilerCrash: report.compilerCrash
        )
    }

    private struct DeduplicationKey: Hashable {
        let severity: AxolotyDiagnosticSeverity
        let message: String
        let location: AxolotySourceLocation?

        init(diagnostic: AxolotyDiagnostic) {
            severity = diagnostic.severity
            message = diagnostic.message
            location = diagnostic.location
        }
    }
}
