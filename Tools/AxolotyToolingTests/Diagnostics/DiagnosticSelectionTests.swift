// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("DiagnosticSelectionTests")
struct DiagnosticSelectionTests {
    private func diagnostic(
        _ severity: AxolotyDiagnosticSeverity,
        _ message: String,
        file: String,
        line: Int
    ) -> AxolotyDiagnostic {
        AxolotyDiagnostic(
            severity: severity,
            message: message,
            location: AxolotySourceLocation(file: file, line: line)
        )
    }

    @Test
    func firstErrorIsAlwaysShown() throws {
        let diagnostics = (0..<20).map { index in diagnostic(.error, "failure \(index)", file: "F.swift", line: index) }
        let selected = AxolotyDiagnosticSelection.apply(
            AxolotyDiagnosticReport(tool: .swiftCompiler, diagnostics: diagnostics)
        )
        #expect(selected.diagnostics.first?.message == "failure 0")
        #expect(selected.diagnostics.count == AxolotyDiagnosticSelection.defaultMaximumErrors)
        #expect(selected.suppressedCount == 20 - AxolotyDiagnosticSelection.defaultMaximumErrors)
    }

    @Test
    func warningsAreBoundedSeparately() throws {
        let warnings = (0..<10).map { index in diagnostic(.warning, "warning \(index)", file: "W.swift", line: index) }
        let selected = AxolotyDiagnosticSelection.apply(
            AxolotyDiagnosticReport(tool: .swiftCompiler, diagnostics: warnings)
        )
        #expect(selected.diagnostics.count == AxolotyDiagnosticSelection.defaultMaximumWarnings)
        #expect(selected.suppressedCount == 10 - AxolotyDiagnosticSelection.defaultMaximumWarnings)
    }

    @Test
    func notesPerDiagnosticAreBounded() throws {
        let notes = (0..<10).map { AxolotyDiagnosticNote(message: "note \($0)") }
        let withNotes = AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [
                AxolotyDiagnostic(severity: .error, message: "failure", notes: notes),
            ]
        )
        let selected = AxolotyDiagnosticSelection.apply(withNotes)
        #expect(selected.diagnostics.first?.notes.count == AxolotyDiagnosticSelection.defaultMaximumNotesPerDiagnostic)
        #expect(selected.suppressedCount == 10 - AxolotyDiagnosticSelection.defaultMaximumNotesPerDiagnostic)
    }

    @Test
    func exactDuplicatesAreDeduplicated() throws {
        let report = AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [
                diagnostic(.error, "same", file: "A.swift", line: 1),
                diagnostic(.error, "same", file: "A.swift", line: 1),
                diagnostic(.error, "same", file: "A.swift", line: 2),
            ]
        )
        let selected = AxolotyDiagnosticSelection.apply(report)
        #expect(selected.diagnostics.count == 2)
        #expect(selected.suppressedCount == 1)
    }

    @Test
    func notesAssociatedWithSuppressedErrorsDoNotCountAsShown() throws {
        let report = AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [
                AxolotyDiagnostic(severity: .note, message: "orphan note"),
            ]
        )
        let selected = AxolotyDiagnosticSelection.apply(report)
        #expect(selected.diagnostics.isEmpty)
        #expect(selected.suppressedCount == 1)
    }

    @Test
    func crashIsPreservedThroughSelection() throws {
        let report = AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [],
            compilerCrash: AxolotyCompilerCrash(summary: "Stack dump:\n0. swift-frontend")
        )
        let selected = AxolotyDiagnosticSelection.apply(report)
        #expect(selected.compilerCrash?.summary.contains("swift-frontend") == true)
    }
}
