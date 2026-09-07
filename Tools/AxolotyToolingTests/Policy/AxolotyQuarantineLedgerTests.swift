// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import AxolotyTooling
import Foundation
import Testing

private func makeEntry(
    prefixes: [String] = ["commandRunner"],
    nodeIds: [String] = ["test-tooling-check"],
    deadline: String = "2026-10-18"
) -> AxolotyQuarantineEntry {
    AxolotyQuarantineEntry(
        id: "q-fixture",
        testNamePrefixes: prefixes,
        nodeIds: nodeIds,
        owner: "someone",
        ticket: "#781",
        evidence: "https://example.invalid/comment",
        deadline: deadline,
        reason: "fixture"
    )
}

private let referenceNow = DateFormatter.axolotyQuarantineFixtureDate("2026-09-07")

@Test
func quarantineLedgerMatchesAnUnexpiredPrefixInItsOwningNode() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(ledger.isQuarantined("commandRunnerFlakesSometimes()", nodeID: "test-tooling-check"))
}

@Test
func quarantineLedgerIgnoresAMatchingPrefixInAnotherNode() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(!ledger.isQuarantined("commandRunnerFlakesSometimes()", nodeID: "test-tooling"))
}

@Test
func quarantineLedgerIgnoresANonMatchingName() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(!ledger.isQuarantined("projectCommandFlakesSometimes()", nodeID: "test-tooling-check"))
}

@Test
func quarantineLedgerTreatsAnExpiredEntryAsNonSuppressing() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry(deadline: "2020-01-01")], now: referenceNow)
    #expect(!ledger.isQuarantined("commandRunnerFlakesSometimes()", nodeID: "test-tooling-check"))
}

@Test
func quarantineLedgerTreatsAMalformedDeadlineAsExpired() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry(deadline: "not-a-date")], now: referenceNow)
    #expect(!ledger.isQuarantined("commandRunnerFlakesSometimes()", nodeID: "test-tooling-check"))
}

@Test
func allQuarantinedRequiresEveryNameCovered() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(ledger.allQuarantined(["commandRunnerOne()", "commandRunnerTwo()"], nodeID: "test-tooling-check"))
    #expect(!ledger.allQuarantined(["commandRunnerOne()", "somethingElse()"], nodeID: "test-tooling-check"))
}

@Test
func allQuarantinedRejectsAnEmptySet() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(!ledger.allQuarantined([], nodeID: "test-tooling-check"))
}

@Test
func allQuarantinedRejectsAMissingNodeID() {
    let ledger = AxolotyQuarantineLedger(entries: [makeEntry()], now: referenceNow)
    #expect(!ledger.allQuarantined(["commandRunnerOne()"], nodeID: nil))
}

private extension DateFormatter {
    static func axolotyQuarantineFixtureDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { fatalError("invalid fixture date") }
        return date
    }
}
