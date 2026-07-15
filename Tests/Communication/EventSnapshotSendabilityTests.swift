// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import Testing

@testable import Axoloty

/// Compile-time Sendable witness tests for the one-way communication event snapshots.
@Suite
struct EventSnapshotSendabilityTests {

    @Test
    func advertiseEventSnapshotIsSendable() {
        let snapshot = AdvertiseEventSnapshot(
            object: sampleObject(),
            privateData: sampleData()
        )
        assertSendable(snapshot)
    }

    @Test
    func deadvertiseEventSnapshotIsSendable() {
        let snapshot = DeadvertiseEventSnapshot(objectIds: ["550e8400-e29b-41d4-a716-446655440000"])
        assertSendable(snapshot)
    }

    @Test
    func channelEventSnapshotIsSendable() {
        let snapshot = ChannelEventSnapshot(
            objects: [sampleObject()],
            channelId: "channel-a",
            privateData: sampleData()
        )
        assertSendable(snapshot)
    }

    @Test
    func updateEventSnapshotIsSendable() {
        let snapshot = UpdateEventSnapshot(object: sampleObject())
        assertSendable(snapshot)
    }

    @Test
    func discoverEventSnapshotIsSendable() {
        let snapshot = DiscoverEventSnapshot(
            externalId: "external-1",
            objectTypes: ["coaty.Custom"],
            coreTypes: ["CoatyObject"]
        )
        assertSendable(snapshot)
    }

    @Test
    func callEventSnapshotIsSendable() {
        let snapshot = CallEventSnapshot(
            operation: "doThing",
            parameters: sampleData(),
            filter: sampleData()
        )
        assertSendable(snapshot)
    }

    @Test
    func queryEventSnapshotIsSendable() {
        let snapshot = QueryEventSnapshot(
            objectTypes: ["coaty.Custom"],
            coreTypes: ["CoatyObject"],
            objectFilter: sampleData(),
            objectJoinConditions: [sampleData()]
        )
        assertSendable(snapshot)
    }
}

/// A compile-time witness that the given value conforms to `Sendable`.
private func assertSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func sampleObject() -> CoatyObjectSnapshot {
    CoatyObjectSnapshot(
        objectId: "550e8400-e29b-41d4-a716-446655440000",
        coreType: "CoatyObject",
        objectType: "coaty.CoatyObject",
        name: "Sample Object"
    )
}

private func sampleData() -> Data {
    Data("{\"key\":\"value\"}".utf8)
}
