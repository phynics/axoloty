// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Parses build output without inventing unavailable metrics.
public enum AxolotyTimingOutputParser {
    /// Extracts the largest explicit `[step/total]` marker, or a count of known
    /// compile/link lines when the backend does not emit a total.
    /// - Parameter output: Captured standard output and standard error.
    /// - Returns: The parsed build-step metric or an unavailable metric.
    public static func stepMetric(from output: String) -> AxolotyTimingMetric {
        var explicitTotal = 0
        var fallbackCount = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if let open = text.firstIndex(of: "["),
               let slash = text[open...].firstIndex(of: "/"),
               let close = text[slash...].firstIndex(of: "]") {
                let totalText = text[text.index(after: slash)..<close]
                if let total = Int(totalText), total > explicitTotal {
                    explicitTotal = total
                }
            }
            let lower = text.lowercased()
            if lower.contains("compiling ") || lower.contains("linking ") || lower.contains("building ") {
                fallbackCount += 1
            }
        }
        if explicitTotal > 0 { return AxolotyTimingMetric(value: explicitTotal) }
        if fallbackCount > 0 { return AxolotyTimingMetric(value: fallbackCount, diagnostic: "counted recognized build lines") }
        return AxolotyTimingMetric(unavailable: "build output contained no recognized step markers")
    }

    /// Extracts ccache hit/miss counters when present in command output.
    /// - Parameter output: Captured command output, including optional ccache statistics.
    /// - Returns: Parsed cache counters or an unavailable metric.
    public static func cacheMetric(from output: String) -> AxolotyTimingCacheStats {
        var hits: Int?
        var misses: Int?
        var splitHits = 0
        var sawSplitHits = false
        var before = AxolotyTimingCacheSnapshot(hits: 0, misses: 0)
        var after = AxolotyTimingCacheSnapshot(hits: 0, misses: 0)
        var sawBefore = false
        var sawAfter = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let lower = text.lowercased()
            let fields = lower.split(whereSeparator: \.isWhitespace)
            if fields.first == "ccache_before" || fields.first == "ccache_after" {
                guard fields.count >= 3, let value = Int(fields[2]) else { continue }
                let isBefore = fields[0] == "ccache_before"
                let key = fields[1]
                if isBefore { sawBefore = true } else { sawAfter = true }
                if key == "direct_cache_hit" || key == "preprocessed_cache_hit" || key == "cache_hit" {
                    let snapshot = isBefore ? before : after
                    let updated = AxolotyTimingCacheSnapshot(hits: snapshot.hits + value, misses: snapshot.misses)
                    if isBefore { before = updated } else { after = updated }
                } else if key == "cache_miss" {
                    let snapshot = isBefore ? before : after
                    let updated = AxolotyTimingCacheSnapshot(hits: snapshot.hits, misses: value)
                    if isBefore { before = updated } else { after = updated }
                }
                continue
            }
            if fields.first == "direct_cache_hit" || fields.first == "preprocessed_cache_hit" {
                if let value = fields.dropFirst().first.flatMap({ Int($0) }) {
                    splitHits += value
                    sawSplitHits = true
                }
            } else if lower.contains("cache hits") || lower.hasPrefix("hits:") || fields.first == "cache_hit" {
                hits = firstInteger(in: text) ?? hits
            }
            if lower.contains("cache misses") || lower.hasPrefix("misses:") || fields.first == "cache_miss" {
                misses = firstInteger(in: text) ?? misses
            }
        }
        if sawBefore, sawAfter {
            return AxolotyTimingCacheStats(
                hits: max(0, after.hits - before.hits),
                misses: max(0, after.misses - before.misses),
                diagnostic: "sampled ccache counters before and after command"
            )
        }
        if hits == nil, sawSplitHits { hits = splitHits }
        let missText = misses.map(String.init) ?? "unavailable"
        let diagnostic = hits.map { "hits=\($0) misses=\(missText)" }
        return AxolotyTimingCacheStats(hits: hits, misses: misses, diagnostic: diagnostic)
    }

    /// Bounds diagnostics so a compiler failure cannot flood JSON output.
    /// - Parameters:
    ///   - text: Diagnostic text to trim and bound.
    ///   - limit: Maximum number of characters retained.
    /// - Returns: Bounded nonempty text, or `nil` for empty input.
    public static func boundedDiagnostic(_ text: String, limit: Int = 512) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }

    private static func firstInteger(in text: String) -> Int? {
        guard let firstDigit = text.firstIndex(where: \.isNumber) else { return nil }
        let suffix = text[firstDigit...]
        let digits = suffix[firstDigit...].prefix { character in character.isNumber || character == "," }
        let normalized = String(digits).replacingOccurrences(of: ",", with: "")
        return Int(normalized)
    }
}
