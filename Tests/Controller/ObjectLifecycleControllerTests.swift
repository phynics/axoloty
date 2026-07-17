//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  ObjectLifecycleControllerTests.swift
//  Axoloty

import Axoloty
import Foundation
import Testing

@MainActor
struct ObjectLifecycleControllerTests {
    /// NOTE: Make sure that a coaty broker (or just any MQTT broker) is running on the localhost before running
    @Test
    func test() async throws {
        // Configure the first coaty agent
        let mqttOptions1 = MQTTClientOptions(host: "127.0.0.1",
                                             port: UInt16(1883))
        let communication1 = CommunicationOptions(mqttClientOptions: mqttOptions1,
                                                  shouldAutoStart: false)

        let configuration1 = Configuration(communication: communication1)

        let controllers1: [String: Controller.Type] = ["ObjectLifecycleController": ObjectLifecycleController.self]

        let components1 = Components(controllers: controllers1,
                                     objectTypes: [])

        let coatyAgent1Container = Container.resolve(components: components1,
                                                     configuration: configuration1)

        // Configure the second coaty agent
        let mqttOptions2 = MQTTClientOptions(host: "127.0.0.1",
                                             port: UInt16(1883))
        let communication2 = CommunicationOptions(mqttClientOptions: mqttOptions2,
                                                  shouldAutoStart: false)

        let configuration2 = Configuration(communication: communication2)

        let components2 = Components(controllers: .init(),
                                     objectTypes: [])

        let coatyAgent2Container = Container.resolve(components: components2,
                                                     configuration: configuration2)

        let controller = try #require(
            coatyAgent1Container.getController(name: "ObjectLifecycleController") as? ObjectLifecycleController
        )

        let testLocationId: CoatyUUID = .init()

        // Create the testLog object that is used for testing purposes
        let testLog = Log(logLevel: .info,
                          logMessage: "Test log. Ignore.",
                          logDate: "Test date")
        testLog.locationId = testLocationId

        let locationId = testLocationId.string
        let stream = try await controller.observeObjectLifecycleSnapshotsByObjectType(
            with: Log.objectType,
            objectFilter: { $0.locationId == locationId }
        )
        var iterator = stream.makeAsyncIterator()
        try await withTimeout("agent1 container ready") { try await coatyAgent1Container.startAndWaitUntilReady() }
        try await withTimeout("agent2 container ready") { try await coatyAgent2Container.startAndWaitUntilReady() }

        // Advertise the created test object from the second agent
        try coatyAgent2Container.communicationManager?.publishAdvertise(
            AdvertiseEvent.with(object: testLog)
        )
        let added = try await nextValue(&iterator, timeout: .seconds(5))
        #expect(added.added?.contains { $0.objectId == testLog.objectId.string } == true)
        #expect(added.changed == nil)
        #expect(added.removed == nil)

        // Change the existing object and advertise again from the second agent
        testLog.name = "Modified for test purposes. Ignore."
        try coatyAgent2Container.communicationManager?.publishAdvertise(
            AdvertiseEvent.with(object: testLog)
        )
        let changed = try await nextValue(&iterator, timeout: .seconds(5))
        #expect(changed.added == nil)
        #expect(changed.changed?.contains { $0.objectId == testLog.objectId.string } == true)
        #expect(changed.removed == nil)

        // Removed
        coatyAgent2Container.communicationManager?.publishDeadvertise(
            DeadvertiseEvent.with(objectIds: [testLog.objectId])
        )
        let removed = try await nextValue(&iterator, timeout: .seconds(5))
        #expect(removed.added == nil)
        #expect(removed.changed == nil)
        #expect(removed.removed?.contains { $0.objectId == testLog.objectId.string } == true)

        coatyAgent1Container.shutdown()
        coatyAgent2Container.shutdown()
    }
}

// `nextValue` is shared from Tests/Testing/AsyncWaiting.swift.
