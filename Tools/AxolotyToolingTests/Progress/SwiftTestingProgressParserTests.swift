// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("SwiftTestingProgressParserTests")
struct SwiftTestingProgressParserTests {
    private func consume(
        _ lines: [String],
        stream: AxolotyCommandOutputStream = .standardOutput
    ) -> [AxolotyCommandProgress] {
        var parser = SwiftTestingProgressParser()
        return lines.compactMap { parser.consume(line: $0, stream: stream) }
    }

    @Test
    func runStartedMapsToTesting() throws {
        let events = consume(["◇ Test run started."])
        #expect(events.count == 1)
        #expect(events.first?.phase == .testing)
        #expect(events.first?.counters?.passed == 0)
    }

    @Test
    func runTotalIsUsedWithoutFabrication() throws {
        let events = consume(["◇ Test run with 148 tests in 12 suites started on host."])
        let progress = try #require(events.last)
        #expect(progress.total == 148)
        #expect(progress.completed == 0)
    }

    @Test
    func testStartedUpdatesCurrentDetail() throws {
        let events = consume([
            "◇ Suite MQTTBindingTests started.",
            "◇ Test \"connect()\" started.",
        ])
        let last = try #require(events.last)
        #expect(last.target == "MQTTBindingTests")
        #expect(last.detail == "connect()")
        #expect(last.phase == .testing)
    }

    @Test
    func passedFailedSkippedIncrementCounters() throws {
        let events = consume([
            "✔ Test \"foo()\" passed after 0.001 seconds.",
            "✘ Test \"bar()\" recorded an issue at Sources/Foo.swift:1:1.",
            "➜ Test \"baz()\" skipped.",
        ])
        let counters = try #require(events.last?.counters)
        #expect(counters.passed == 1)
        #expect(counters.failed == 1)
        #expect(counters.skipped == 1)
        #expect(events.last?.completed == 3)
    }

    @Test
    func skipGlyphVariantIsRecognized() throws {
        let events = consume(["↩ Test \"baz()\" skipped."])
        #expect(events.last?.counters?.skipped == 1)
    }

    @Test
    func runSummaryReportsCompletionWithTotal() throws {
        let events = consume([
            "◇ Test run with 148 tests in 12 suites started on host.",
            "✔ Test run with 148 tests in 12 suites passed after 12.6 seconds.",
        ])
        let summary = try #require(events.last)
        #expect(summary.phase == .completed)
        #expect(summary.total == 148)
        #expect(summary.completed == 148)
    }

    @Test
    func nonTestingLinesAreIgnored() throws {
        #expect(consume(["Compiling Axoloty Broker.swift"]).isEmpty)
        #expect(consume(["[84/217] Compiling Axoloty MQTTClient.swift"]).isEmpty)
        #expect(consume(["random output with Test in the middle"]).isEmpty)
        #expect(consume([""]).isEmpty)
    }

    @Test
    func unquotedNamesAreRecognized() throws {
        let events = consume(["✔ Test foo() passed after 0.1 seconds."])
        #expect(events.last?.detail == "foo()")
        #expect(events.last?.counters?.passed == 1)
    }

    @Test
    func interleavedStreamsProduceConsistentCounters() throws {
        let stdoutEvents = consume([
            "◇ Test run with 2 tests in 1 suite started on host.",
            "◇ Test \"one()\" started.",
            "✔ Test \"one()\" passed after 0.1 seconds.",
        ], stream: .standardOutput)
        let stderrEvents = consume([
            "✘ Test \"two()\" recorded an issue at Sources/Foo.swift:2:1.",
        ], stream: .standardError)
        #expect(stdoutEvents.last?.counters?.passed == 1)
        #expect(stdoutEvents.last?.counters?.failed == 0)
        #expect(stderrEvents.first?.counters?.failed == 1)
    }

    @Test
    func supportsEveryCommand() throws {
        #expect(SwiftTestingProgressParser().supports(AxolotyCommandPlan(executable: "swift", arguments: ["test"])))
        #expect(SwiftTestingProgressParser().supports(AxolotyCommandPlan(executable: "axoloty-tool", arguments: ["check", "ci"])))
    }
}
