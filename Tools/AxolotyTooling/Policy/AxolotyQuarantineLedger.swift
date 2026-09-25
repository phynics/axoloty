// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Answers whether a failing test name is covered by an owned, unexpired
/// quarantine entry for a given check node.
///
/// A quarantined failure is never silently discarded: this only tells a
/// caller whether it may downgrade a node's exit code, never whether to
/// suppress the underlying output.
public struct AxolotyQuarantineLedger: Sendable {
    private let entries: [AxolotyQuarantineEntry]
    private let now: Date

    /// Creates a ledger from the manifest's quarantine entries.
    ///
    /// - Parameters:
    ///   - entries: The manifest's declared quarantine entries.
    ///   - now: The clock used for expiry checks, injectable for deterministic tests.
    public init(entries: [AxolotyQuarantineEntry], now: Date = Date()) {
        self.entries = entries
        self.now = now
    }

    /// Whether every name in `testNames` is covered by an unexpired quarantine
    /// entry scoped to `nodeID`. An empty set is never quarantined -- there is
    /// nothing to attribute the node's nonzero exit code to.
    public func allQuarantined(_ testNames: Set<String>, nodeID: String?) -> Bool {
        guard let nodeID, !testNames.isEmpty else { return false }
        return testNames.allSatisfy { isQuarantined($0, nodeID: nodeID) }
    }

    /// Whether one test name is covered by an unexpired quarantine entry
    /// scoped to `nodeID`.
    public func isQuarantined(_ testName: String, nodeID: String) -> Bool {
        entries.contains { entry in
            entry.nodeIds.contains(nodeID)
                && entry.testNamePrefixes.contains { testName.hasPrefix($0) }
                && !isExpired(entry)
        }
    }

    private func isExpired(_ entry: AxolotyQuarantineEntry) -> Bool {
        guard let deadline = Self.date(entry.deadline) else { return true }
        return deadline < now
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
