// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("SwiftDiagnosticParserTests")
struct SwiftDiagnosticParserTests {
    private func parse(_ standardError: String, standardOutput: String = "") -> AxolotyDiagnosticReport? {
        SwiftDiagnosticParser().parse(standardOutput: standardOutput, standardError: standardError)
    }

    @Test
    func singleSwiftErrorWithCaretSnippetIsParsed() throws {
        let report = try #require(parse("""
        Sources/Axoloty/MQTT/Broker.swift:84:21: error: value of type 'MQTTClient' has no member 'connect'
         84 │ client.connect()
            │        ^~~~~~~
        """))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == "value of type 'MQTTClient' has no member 'connect'")
        #expect(diagnostic.location?.file == "Sources/Axoloty/MQTT/Broker.swift")
        #expect(diagnostic.location?.line == 84)
        #expect(diagnostic.location?.column == 21)
        let snippet = try #require(diagnostic.snippet)
        #expect(snippet.text.contains("client.connect()"))
        #expect(snippet.text.contains("^~~~~~~"))
    }

    @Test
    func multipleErrorsAndWarningsAreParsedInOrder() throws {
        let report = try #require(parse("""
        Sources/A.swift:1:1: error: first failure
        Sources/B.swift:2:5: warning: suspicious cast
        Sources/C.swift:3:1: error: second failure
        """))
        #expect(report.diagnostics.count == 3)
        #expect(report.diagnostics[0].severity == .error)
        #expect(report.diagnostics[1].severity == .warning)
        #expect(report.diagnostics[2].location?.file == "Sources/C.swift")
        #expect(report.tool == .swiftCompiler)
    }

    @Test
    func noteAttachesToPrecedingError() throws {
        let report = try #require(parse("""
        Sources/A.swift:10:5: error: cannot convert value
        Sources/B.swift:20:1: note: arguments accepted here
        """))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.notes.count == 1)
        #expect(diagnostic.notes.first?.message == "arguments accepted here")
        #expect(diagnostic.notes.first?.location?.file == "Sources/B.swift")
    }

    @Test
    func unlocatedCompilerErrorIsParsed() throws {
        let report = try #require(parse("error: emit-module command failed"))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message == "emit-module command failed")
        #expect(diagnostic.location == nil)
    }

    @Test
    func linkerFailureIsClassifiedAsLinker() throws {
        let report = try #require(parse("ld.lld: error: undefined symbol: _axoloty_missing"))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.message == "undefined symbol: _axoloty_missing")
        #expect(diagnostic.location == nil)
        #expect(report.tool == .linker)
    }

    @Test
    func linkerFailureVariantIsClassifiedAsLinker() throws {
        let report = try #require(parse("clang: error: linker command failed with exit code 1"))
        #expect(report.tool == .linker)
    }

    @Test
    func stackDumpIsPreservedSeparately() throws {
        let report = try #require(parse("""
        Sources/A.swift:1:1: error: boom
        Stack dump:
        0.  Program arguments: /usr/bin/swift-frontend
        1.  While running pass #0
        """))
        let crash = try #require(report.compilerCrash)
        #expect(crash.summary.contains("Stack dump:"))
        #expect(crash.summary.contains("swift-frontend"))
        #expect(report.diagnostics.first?.message == "boom")
    }

    @Test
    func duplicateDiagnosticsRemainUntilSelectionDeduplicates() throws {
        let report = try #require(parse("""
        Sources/A.swift:1:1: error: same failure
        Sources/A.swift:1:1: error: same failure
        """))
        #expect(report.diagnostics.count == 2)
    }

    @Test
    func malformedLocationsDegradeGracefully() throws {
        let report = try #require(parse("""
        Sources/Weird:Path.swift:notanumber: error: malformed location
        """))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.message == "malformed location")
        #expect(diagnostic.location?.line == 0)
    }

    @Test
    func pathsWithSpacesArePreserved() throws {
        let report = try #require(parse("""
        Sources/My Project/My File.swift:7:3: error: spaced path failure
        """))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.location?.file == "Sources/My Project/My File.swift")
        #expect(diagnostic.location?.line == 7)
    }

    @Test
    func unicodeSourceTextIsPreserved() throws {
        let report = try #require(parse("""
        Sources/Ünïcode.swift:12:4: error: váríable not found – içe
         12 │ let içe = ✅
        """))
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.message.contains("váríable not found – içe"))
        #expect(diagnostic.snippet?.text.contains("let içe = ✅") == true)
    }

    @Test
    func emptyOutputProducesNoReport() throws {
        #expect(parse("") == nil)
        #expect(parse("normal build output\nBuild complete!") == nil)
    }

    @Test
    func stdoutAndStderrAreBothParsed() throws {
        let report = try #require(parse(
            "",
            standardOutput: "Sources/Out.swift:1:1: error: from stdout"
        ))
        #expect(report.diagnostics.first?.location?.file == "Sources/Out.swift")
    }

    @Test
    func snippetIsBounded() throws {
        var lines = ["Sources/A.swift:1:1: error: many lines"]
        for index in 0...30 {
            lines.append(" \(index) │ let x\(index) = \(index)")
        }
        let report = try #require(parse(lines.joined(separator: "\n")))
        let snippetText = try #require(report.diagnostics.first?.snippet?.text)
        #expect(snippetText.split(separator: "\n").count <= 10)
    }
}
