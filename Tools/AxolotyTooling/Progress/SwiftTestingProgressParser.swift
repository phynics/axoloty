// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses Swift Testing run progress from subprocess output.
///
/// The parser generalizes the output collector's earlier started-test
/// tracking. It recognizes the stable Swift Testing event glyphs (`◇`, `✔`,
/// `✘`, `↩`, `➜`) and the run-level summary. A total is only reported when
/// the tool actually emitted one; it is never fabricated.
public struct SwiftTestingProgressParser: AxolotyCommandProgressParsing {
    private var currentSuite: String?
    private var currentTest: String?
    private var counters = AxolotyCommandProgressCounters()
    private var failedTests = Set<String>()

    /// Every test name reported failed or as having recorded an issue, across
    /// the whole run. This is a live-progress parser incidentally reused as
    /// the only source of per-test outcome, so a caller deciding whether a
    /// node's failure is quarantine-eligible reads this after the command
    /// completes rather than during live rendering.
    public var failedTestNames: Set<String> { failedTests }

    /// Creates a test progress parser.
    public init() {}

    /// Whether the parser applies to the command.
    ///
    /// Test binaries run both directly (`swift test`) and as children of
    /// check invocations, so the parser consumes every command and simply
    /// ignores lines that carry no Swift Testing event.
    ///
    /// - Parameter command: The planned subprocess command.
    /// - Returns: Always `true`.
    public func supports(_ command: AxolotyCommandPlan) -> Bool { true }

    /// Consumes one complete output line.
    ///
    /// - Parameters:
    ///   - line: One complete logical line without its terminating newline.
    ///   - stream: The stream the line arrived on; Swift Testing uses stdout.
    /// - Returns: Progress for recognized test event and summary lines.
    public mutating func consume(
        line: String,
        stream: AxolotyCommandOutputStream
    ) -> AxolotyCommandProgress? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, Self.eventGlyphs.contains(first) else { return nil }
        let body = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)

        if body.hasPrefix("Test run") || body.hasPrefix("run started") {
            return consumeRunSummary(body)
        }
        if body.hasPrefix("Suite ") {
            let suite = Self.name(
                from: String(body.dropFirst("Suite ".count)),
                terminator: " started"
            )
            if let suite { currentSuite = suite }
            return AxolotyCommandProgress(
                phase: .testing,
                target: currentSuite,
                detail: currentTest,
                counters: counters
            )
        }
        guard body.hasPrefix("Test ") else { return nil }
        return consumeTestCase(String(body.dropFirst("Test ".count)))
    }

    private mutating func consumeRunSummary(_ body: String) -> AxolotyCommandProgress? {
        if body.contains("run started") {
            return AxolotyCommandProgress(phase: .testing, counters: counters)
        }
        guard let total = Self.runTotal(in: body) else { return nil }
        let completed = counters.passed + counters.failed + counters.skipped
        if body.contains(" passed") || body.contains(" failed") || body.contains(" skipped") {
            return AxolotyCommandProgress(
                phase: .completed,
                completed: total,
                total: total,
                target: currentSuite,
                detail: currentTest,
                counters: counters
            )
        }
        return AxolotyCommandProgress(
            phase: .testing,
            completed: min(completed, total),
            total: total,
            target: currentSuite,
            detail: currentTest,
            counters: counters
        )
    }

    private mutating func consumeTestCase(_ body: String) -> AxolotyCommandProgress? {
        let name: String?
        var outcome: AxolotyCommandProgress?
        if body.contains(" passed") {
            name = Self.name(from: body, terminator: " passed")
            counters.passed += 1
            outcome = AxolotyCommandProgress(
                phase: .testing,
                completed: counterTotal,
                target: currentSuite,
                detail: name ?? currentTest,
                counters: counters
            )
            currentTest = name ?? currentTest
        } else if body.contains(" failed") || body.contains(" recorded an issue") {
            name = Self.name(from: body, terminator: " failed")
                ?? Self.name(from: body, terminator: " recorded an issue")
            counters.failed += 1
            if let name { failedTests.insert(name) }
            outcome = AxolotyCommandProgress(
                phase: .testing,
                completed: counterTotal,
                target: currentSuite,
                detail: name ?? currentTest,
                counters: counters
            )
            currentTest = name ?? currentTest
        } else if body.contains(" skipped") {
            name = Self.name(from: body, terminator: " skipped")
            counters.skipped += 1
            outcome = AxolotyCommandProgress(
                phase: .testing,
                completed: counterTotal,
                target: currentSuite,
                detail: name ?? currentTest,
                counters: counters
            )
            currentTest = name ?? currentTest
        } else if let startedName = Self.name(from: body, terminator: " started") {
            currentTest = startedName
            outcome = AxolotyCommandProgress(
                phase: .testing,
                target: currentSuite,
                detail: startedName,
                counters: counters
            )
        }
        return outcome
    }

    private var counterTotal: Int {
        counters.passed + counters.failed + counters.skipped
    }

    private static let eventGlyphs: Set<Character> = ["◇", "✔", "✘", "↩", "➜"]

    private static func name(from body: String, terminator: String) -> String? {
        guard let range = body.range(of: terminator) else { return nil }
        let raw = String(body[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return raw.isEmpty ? nil : raw
    }

    private static func runTotal(in body: String) -> Int? {
        guard let marker = body.range(of: "Test run with ")
            ?? body.range(of: "run with ") else { return nil }
        let suffix = body[marker.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }
}
