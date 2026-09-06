// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("DiagnosticPresenterTests")
struct DiagnosticPresenterTests {
    private let context = AxolotyDiagnosticPresenter.Context(
        node: "build",
        stage: "check",
        command: "swift build",
        artifactDirectory: ".testing/runs/run-1/invocations/inv-1/commands/004-build"
    )

    private func present(_ report: AxolotyDiagnosticReport) -> String {
        AxolotyDiagnosticPresenter.present(report, context: context)
    }

    @Test
    func primaryErrorRendersLocationMessageSnippetAndNotes() throws {
        let presented = present(AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [
                AxolotyDiagnostic(
                    severity: .error,
                    message: "value of type 'MQTTClient' has no member 'connect'",
                    location: AxolotySourceLocation(file: "Sources/Axoloty/MQTT/Broker.swift", line: 84, column: 21),
                    snippet: AxolotySourceSnippet(text: " 84 │ client.connect()\n    │        ^~~~~~~"),
                    notes: [
                        AxolotyDiagnosticNote(
                            message: "available method is 'open()'",
                            location: AxolotySourceLocation(file: "Sources/Axoloty/MQTT/MQTTClient.swift", line: 31, column: 10)
                        ),
                    ]
                ),
            ]
        ))
        #expect(presented.contains("Sources/Axoloty/MQTT/Broker.swift:84:21"))
        #expect(presented.contains("error: value of type 'MQTTClient' has no member 'connect'"))
        #expect(presented.contains("client.connect()"))
        #expect(presented.contains("^~~~~~~"))
        #expect(presented.contains("note: available method is 'open()'"))
    }

    @Test
    func omittedCountIsReported() throws {
        let diagnostics = (0..<14).map { index in
            AxolotyDiagnostic(
                severity: .error,
                message: "failure \(index)",
                location: AxolotySourceLocation(file: "F.swift", line: index + 1)
            )
        }
        let presented = present(AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: AxolotyDiagnosticSelection.apply(
                AxolotyDiagnosticReport(tool: .swiftCompiler, diagnostics: diagnostics)
            ).diagnostics,
            suppressedCount: 6
        ))
        #expect(presented.contains("8 errors shown"))
        #expect(presented.contains("6 additional diagnostics omitted"))
    }

    @Test
    func traceUsesOnlyKnownPathComponents() throws {
        let presented = present(AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [
                AxolotyDiagnostic(
                    severity: .error,
                    message: "boom",
                    location: AxolotySourceLocation(file: "Sources/Axoloty/MQTT/Broker.swift", line: 84, column: 21)
                ),
            ]
        ))
        #expect(presented.contains("trace:"))
        #expect(presented.contains("build"))
        #expect(presented.contains("swift build"))
        #expect(presented.contains("Broker.swift:84:21"))
        #expect(!presented.lowercased().contains("stack trace"))
    }

    @Test
    func artifactPointerEndsPresentation() throws {
        let presented = present(AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [AxolotyDiagnostic(severity: .error, message: "boom")]
        ))
        #expect(presented.contains("full log:"))
        #expect(presented.contains(".testing/runs/run-1/invocations/inv-1/commands/004-build/stderr.txt"))
    }

    @Test
    func compilerCrashIsRenderedSeparately() throws {
        let presented = present(AxolotyDiagnosticReport(
            tool: .swiftCompiler,
            diagnostics: [AxolotyDiagnostic(severity: .error, message: "boom")],
            compilerCrash: AxolotyCompilerCrash(summary: "Stack dump:\n0. swift-frontend")
        ))
        #expect(presented.contains("compiler crash:"))
        #expect(presented.contains("Stack dump:"))
    }

    @Test
    func unparsedFallbackShowsBoundedTailAndArtifactPointer() throws {
        let standardError = (0..<60).map { "noise line \($0)" }.joined(separator: "\n")
        let presented = AxolotyDiagnosticPresenter.presentUnparsed(
            standardError: standardError,
            context: context
        )
        #expect(presented.contains("Unable to extract structured compiler diagnostics."))
        #expect(presented.contains("noise line 59"))
        #expect(!presented.contains("noise line 0\n"))
        #expect(presented.contains("full log:"))
    }

    @Test
    func missingArtifactDirectoryStaysRepresentable() throws {
        let presented = AxolotyDiagnosticPresenter.presentUnparsed(
            standardError: "",
            context: AxolotyDiagnosticPresenter.Context(node: nil, stage: "check", command: "swift build", artifactDirectory: nil)
        )
        #expect(presented.contains("<artifact directory unavailable>"))
    }
}
