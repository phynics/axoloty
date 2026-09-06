// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

@Suite("CommandProgressRendererTests")
struct CommandProgressRendererTests {
    private let compiling = AxolotyCommandProgress(
        phase: .compiling,
        completed: 84,
        total: 217,
        target: "Axoloty",
        detail: "MQTTClient.swift"
    )

    // MARK: Continuous (non-TTY) renderer

    @Test
    func continuousRendererIsAppendOnlyWithoutANSI() throws {
        let renderer = AxolotyContinuousProgressRenderer()
        let started = try #require(renderer.commandStarted(node: "build", stage: "check", command: "swift build"))
        let update = try #require(renderer.progress(compiling, node: "build", stage: "check", elapsed: 1))
        let fallback = try #require(renderer.fallback(node: "build", stage: "check", command: "swift build", elapsed: 22.4))
        let completed = try #require(renderer.commandCompleted(node: "build", stage: "check", success: true, elapsed: 7.3, reason: nil))
        for text in [started, update, fallback, completed] {
            #expect(!text.contains("\u{1B}"))
            #expect(!text.contains("\r"))
        }
        #expect(started == "[build] swift build started\n")
        #expect(update == "[build] compiling Axoloty 84/217\n")
        #expect(fallback == "[build] still running 22.4s\n")
        #expect(completed == "[build] passed 7.3s\n")
    }

    @Test
    func continuousRendererReportsFailureWithReason() throws {
        let renderer = AxolotyContinuousProgressRenderer()
        let completed = try #require(renderer.commandCompleted(node: "build", stage: "check", success: false, elapsed: 6.8, reason: "timed out"))
        #expect(completed == "[build] failed 6.8s (timed out)\n")
    }

    @Test
    func continuousRendererKeepsCountWithoutTotal() throws {
        let renderer = AxolotyContinuousProgressRenderer()
        let progress = AxolotyCommandProgress(phase: .testing, completed: 50, counters: AxolotyCommandProgressCounters(passed: 50))
        let update = try #require(renderer.progress(progress, node: "test-unit", stage: "check", elapsed: 1))
        #expect(update == "[test-unit] testing 50\n")
    }

    // MARK: Interactive (TTY) renderer

    @Test
    func interactiveRendererOverwritesActiveStatus() throws {
        let renderer = AxolotyInteractiveProgressRenderer()
        _ = try #require(renderer.commandStarted(node: "build", stage: "check", command: "swift build"))
        let first = try #require(renderer.progress(compiling, node: "build", stage: "check", elapsed: 1))
        let second = try #require(renderer.progress(
            AxolotyCommandProgress(phase: .compiling, completed: 100, total: 217, target: "Axoloty"),
            node: "build",
            stage: "check",
            elapsed: 2
        ))
        #expect(first.hasPrefix("\r\u{1B}[2K"))
        #expect(second.hasPrefix("\r\u{1B}[2K"))
        #expect(first.contains("[84/217]"))
        #expect(first.contains("MQTTClient.swift"))
        #expect(second.contains("[100/217]"))
    }

    @Test
    func interactiveCompletionClearsMutableLineAndBecomesPermanent() throws {
        let renderer = AxolotyInteractiveProgressRenderer()
        _ = try #require(renderer.commandStarted(node: "build", stage: "check", command: "swift build"))
        _ = try #require(renderer.progress(compiling, node: "build", stage: "check", elapsed: 1))
        let completed = try #require(renderer.commandCompleted(node: "build", stage: "check", success: true, elapsed: 7.3, reason: nil))
        #expect(completed.hasPrefix("\r\u{1B}[2K"))
        #expect(completed.contains("✓ build 7.3s"))
        #expect(completed.hasSuffix("\n"))
        // No duplicated permanent output on a second completion.
        let again = try #require(renderer.commandCompleted(node: "build", stage: "check", success: true, elapsed: 7.3, reason: nil))
        #expect(again == "✓ build 7.3s\n")
    }

    @Test
    func interactiveFailureClearsMutableLine() throws {
        let renderer = AxolotyInteractiveProgressRenderer()
        _ = try #require(renderer.commandStarted(node: "build", stage: "check", command: "swift build"))
        _ = try #require(renderer.progress(compiling, node: "build", stage: "check", elapsed: 1))
        let completed = try #require(renderer.commandCompleted(node: "build", stage: "check", success: false, elapsed: 6.8, reason: nil))
        #expect(completed.hasPrefix("\r\u{1B}[2K"))
        #expect(completed.contains("✗ build 6.8s"))
        // The clear sequence is emitted only once, before the failure text.
        let permanent = try #require(renderer.permanent("error: no member 'connect'\n"))
        #expect(permanent == "error: no member 'connect'\n")
    }

    @Test
    func interactivePermanentTextEndsWithNewline() throws {
        let renderer = AxolotyInteractiveProgressRenderer()
        let text = try #require(renderer.permanent("compiler crash"))
        #expect(text == "compiler crash\n")
    }
}
