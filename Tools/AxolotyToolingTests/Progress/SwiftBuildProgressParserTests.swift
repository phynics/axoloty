// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("SwiftBuildProgressParserTests")
struct SwiftBuildProgressParserTests {
    private func parse(_ line: String) -> AxolotyCommandProgress? {
        var parser = SwiftBuildProgressParser()
        return parser.consume(line: line, stream: .standardOutput)
    }

    @Test
    func writeSourcesMapsToPreparing() throws {
        let progress = try #require(parse("[1/10] Write sources"))
        #expect(progress.phase == .preparing)
        #expect(progress.completed == 1)
        #expect(progress.total == 10)
        #expect(progress.target == nil)
    }

    @Test
    func compilingMapsToCompilingWithTargetAndDetail() throws {
        let progress = try #require(parse("[3/10] Compiling Foo Bar.swift"))
        #expect(progress.phase == .compiling)
        #expect(progress.completed == 3)
        #expect(progress.total == 10)
        #expect(progress.target == "Foo")
        #expect(progress.detail == "Bar.swift")
    }

    @Test
    func compilingWithoutFileHasNoDetail() throws {
        let progress = try #require(parse("[4/10] Compiling Foo"))
        #expect(progress.phase == .compiling)
        #expect(progress.target == "Foo")
        #expect(progress.detail == nil)
    }

    @Test
    func emittingModuleMapsToEmitting() throws {
        let progress = try #require(parse("[5/10] Emitting module Foo"))
        #expect(progress.phase == .emittingModule)
        #expect(progress.completed == 5)
        #expect(progress.total == 10)
        #expect(progress.target == "Foo")
    }

    @Test
    func linkingMapsToLinking() throws {
        let progress = try #require(parse("[9/10] Linking FooTests"))
        #expect(progress.phase == .linking)
        #expect(progress.completed == 9)
        #expect(progress.total == 10)
        #expect(progress.target == "FooTests")
    }

    @Test
    func buildCompleteMapsToCompleted() throws {
        let progress = try #require(parse("Build complete!"))
        #expect(progress.phase == .completed)
    }

    @Test
    func buildingBannerMapsToPlanning() throws {
        let progress = try #require(parse("Building for debugging..."))
        #expect(progress.phase == .planning)
    }

    @Test
    func unknownBracketActionKeepsCounterWithoutInventingPhase() throws {
        let progress = try #require(parse("[2/10] Merging module Foo"))
        #expect(progress.phase == .running)
        #expect(progress.completed == 2)
        #expect(progress.total == 10)
    }

    @Test
    func malformedCountersAreIgnored() throws {
        #expect(parse("[10/10] Compiling Foo Bar.swift") != nil)
        #expect(parse("[12/10] Compiling Foo Bar.swift") == nil)
        #expect(parse("[a/b] Compiling Foo Bar.swift") == nil)
        #expect(parse("[] Compiling Foo Bar.swift") == nil)
        #expect(parse("") == nil)
        #expect(parse("random text") == nil)
    }

    @Test
    func stepMarkerScanningMatchesTimingParserInterpretation() throws {
        let marker = try #require(SwiftBuildProgressParser.stepMarker(in: "[139/217] Emitting module Axoloty"))
        #expect(marker.completed == 139)
        #expect(marker.total == 217)
        #expect(marker.action == "Emitting module Axoloty")
    }

    @Test
    func supportsEveryCommandAndIgnoresNonBuildLines() throws {
        #expect(SwiftBuildProgressParser().supports(AxolotyCommandPlan(executable: "swift", arguments: ["build"])))
        #expect(SwiftBuildProgressParser().supports(AxolotyCommandPlan(executable: "/bin/sh", arguments: ["-c", "swift build"])))
        #expect(SwiftBuildProgressParser().supports(AxolotyCommandPlan(executable: "axoloty-tool", arguments: ["check", "ci"])))
        var parser = SwiftBuildProgressParser()
        #expect(parser.consume(line: "unrelated output", stream: .standardOutput) == nil)
    }

    @Test
    func fractionNeverFabricates() throws {
        #expect(parse("[84/217] Compiling Axoloty MQTTClient.swift")?.fraction == 84.0 / 217.0)
        #expect(parse("Build complete!")?.fraction == nil)
        #expect(parse("[3/10] Compiling Foo Bar.swift")?.fraction == 0.3)
    }
}
