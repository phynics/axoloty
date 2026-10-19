// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

struct AxolotyCommandPhaseTimings: Equatable, Sendable {
    let compilationSeconds: TimeInterval?
    let testSeconds: TimeInterval?
}

enum AxolotyCommandPhaseTimingParser {
    static func parse(_ output: String) -> AxolotyCommandPhaseTimings {
        guard let compilationPattern = try? NSRegularExpression(
            pattern: #"Build complete! \(([0-9]+(?:\.[0-9]+)?) (?:secs|seconds)\)"#
        ), let testPattern = try? NSRegularExpression(
            pattern: #"(?:passed|failed) after ([0-9]+(?:\.[0-9]+)?) seconds"#
        ) else {
            return AxolotyCommandPhaseTimings(compilationSeconds: nil, testSeconds: nil)
        }
        return AxolotyCommandPhaseTimings(
            compilationSeconds: Self.totalMatches(compilationPattern, in: output),
            testSeconds: Self.totalMatches(testPattern, in: output)
        )
    }

    private static func totalMatches(_ expression: NSRegularExpression, in text: String) -> TimeInterval? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { total, match in
            guard let range = Range(match.range(at: 1), in: text),
                  let duration = TimeInterval(text[range]) else { return total }
            return total + duration
        }
    }
}
