// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("CommandProgressTrackerTests")
struct CommandProgressTrackerTests {
    private final class EmissionRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var emissions: [(live: String, plain: String)] = []

        func append(live: String, plain: String) {
            lock.lock()
            emissions.append((live, plain))
            lock.unlock()
        }

        var liveTexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return emissions.map(\.live)
        }

        var plainTexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return emissions.map(\.plain)
        }
    }

    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: TimeInterval
        init(start: TimeInterval = 1_000) { current = start }
        var now: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            current += seconds
        }
    }

    private func makeTracker(
        clock: MutableClock,
        recorder: EmissionRecorder,
        minimumUpdateInterval: TimeInterval = 0.5
    ) -> AxolotyCommandProgressTracker {
        AxolotyCommandProgressTracker(
            node: "build",
            stage: "check",
            command: AxolotyCommandPlan(executable: "swift", arguments: ["build"]),
            renderer: AxolotyContinuousProgressRenderer(),
            emit: { live, plain in recorder.append(live: live, plain: plain) },
            now: { clock.now },
            minimumUpdateInterval: minimumUpdateInterval,
            fallbackInterval: 5
        )
    }

    @Test
    func hundredsOfCompileEventsProduceBoundedEmissions() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        for step in 1...300 {
            tracker.consumeLine("[\(step)/600] Compiling Axoloty File\(step).swift", stream: .standardOutput)
            clock.advance(0.01)
        }
        // Rate cap is 2/s and the clock only advanced 3s: bounded output.
        let emissions = recorder.liveTexts.count
        #expect(emissions > 0)
        #expect(emissions <= 12)
    }

    @Test
    func progressBucketsBoundEmissionsAcrossLargeRuns() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        for step in stride(from: 1, through: 217, by: 1) {
            tracker.consumeLine("[\(step)/217] Compiling Axoloty File\(step).swift", stream: .standardOutput)
            clock.advance(0.6)
        }
        // One line per second with a 5% bucket and 0.5s cap: well below 217.
        #expect(recorder.liveTexts.count < 40)
        #expect(recorder.liveTexts.count > 5)
    }

    @Test
    func phaseChangesAreNeverThrottled() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.consumeLine("[1/10] Write sources", stream: .standardOutput)
        clock.advance(0.01)
        tracker.consumeLine("[2/10] Compiling Foo Bar.swift", stream: .standardOutput)
        clock.advance(0.01)
        tracker.consumeLine("[3/10] Emitting module Foo", stream: .standardOutput)
        let texts = recorder.liveTexts.joined()
        #expect(texts.contains("preparing"))
        #expect(texts.contains("compiling"))
        #expect(texts.contains("emitting"))
    }

    @Test
    func targetChangesAreNeverThrottled() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.consumeLine("[1/10] Compiling Foo Bar.swift", stream: .standardOutput)
        clock.advance(0.01)
        tracker.consumeLine("[2/10] Compiling Baz Qux.swift", stream: .standardOutput)
        let texts = recorder.liveTexts.joined()
        #expect(texts.contains("Foo"))
        #expect(texts.contains("Baz"))
    }

    @Test
    func testFailuresAreNeverThrottled() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.consumeLine("✔ Test \"one()\" passed after 0.1 seconds.", stream: .standardOutput)
        clock.advance(0.01)
        tracker.consumeLine("✘ Test \"two()\" recorded an issue at Sources/Foo.swift:1:1.", stream: .standardOutput)
        let texts = recorder.liveTexts.joined()
        #expect(texts.contains("testing 1"))
        #expect(texts.contains("testing 2"))
    }

    @Test
    func fallbackEmitsAfterSilenceAndStaysBounded() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.fallback(elapsed: 0.1)
        #expect(!recorder.liveTexts.joined().contains("still running"))
        clock.advance(6)
        tracker.fallback(elapsed: 6.1)
        #expect(recorder.liveTexts.joined().contains("[build] still running 6.1s"))
        clock.advance(5)
        tracker.fallback(elapsed: 11.3)
        #expect(recorder.liveTexts.filter { $0.contains("still running") }.count == 2)
    }

    @Test
    func parserActivityDefersFallback() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.consumeLine("[1/10] Write sources", stream: .standardOutput)
        clock.advance(6)
        tracker.fallback(elapsed: 6.1)
        #expect(!recorder.liveTexts.contains("still running"))
    }

    @Test
    func completeEmitsExactlyOnePermanentLine() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.start()
        tracker.complete(success: true, elapsed: 7.3)
        tracker.complete(success: true, elapsed: 7.3)
        let completions = recorder.liveTexts.filter { $0.contains("passed 7.3s") }
        #expect(completions.count == 1)
    }

    @Test
    func failureTextIsEmittedUnthrottledAndPlain() throws {
        let clock = MutableClock()
        let recorder = EmissionRecorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        tracker.emitFailureText("✗ Build\nerror: something failed\n")
        #expect(recorder.liveTexts.joined().contains("error: something failed"))
        #expect(recorder.plainTexts.joined().contains("error: something failed"))
    }

    @Test
    func plainTextStripsANSI() throws {
        #expect(
            AxolotyCommandProgressTracker.strippingANSI("\r\u{1B}[2K  compiling Axoloty")
                == "  compiling Axoloty"
        )
        #expect(AxolotyCommandProgressTracker.strippingANSI("no escapes") == "no escapes")
    }
}
