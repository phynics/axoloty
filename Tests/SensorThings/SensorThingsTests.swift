//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  SensorThingsTests.swift
//  Axoloty

import Axoloty
import Foundation
import Testing

// NOTE: This test case sometimes fails to run because of some problems related to thread scheduling
// If possible run these tests against a physical device (e.g. iPhone), instead of Simulator.
// Please also note that test results are also often influenced by the current stress on the CPU.

// MARK: - Communication tests.

@MainActor
struct SensorThingsTests {
    static let TEST_TIMEOUT = 10

    static let SENSOR_THINGS_TYPES_SET = [
        SensorThingsTypes.OBJECT_TYPE_FEATURE_OF_INTEREST,
        SensorThingsTypes.OBJECT_TYPE_OBSERVATION,
        SensorThingsTypes.OBJECT_TYPE_SENSOR,
        SensorThingsTypes.OBJECT_TYPE_THING,
    ]

    // MARK: - Test methods.

    @Test
    func advertise() async throws {
        let mqttClientOptions1 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: false)
        let controllerOptions1 = ControllerOptions(extra: ["name": "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController": controllerOptions1])
        let configuration1 = Configuration(common: nil,
                                           communication: communicationOptions1,
                                           controllers: controllersConfig1,
                                           databases: nil)
        let controllers1: [String: Controller.Type] = ["MockEmitterController": MockEmitterController.self]
        let components1 = Components(controllers: controllers1, objectTypes: [])
        let container1 = Container.resolve(components: components1, configuration: configuration1)

        let mqttClientOptions2 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions2 = CommunicationOptions(mqttClientOptions: mqttClientOptions2, shouldAutoStart: false)
        let configuration2 = Configuration(communication: communicationOptions2)
        let controllers2: [String: Controller.Type] = ["MockReceiverController": MockReceiverController.self]
        let components2 = Components(controllers: controllers2, objectTypes: [])
        let container2 = Container.resolve(components: components2, configuration: configuration2)

        try await withTimeout("container1 ready") { try await container1.startAndWaitUntilReady() }
        try await withTimeout("container2 ready") { try await container2.startAndWaitUntilReady() }

        let eventCount = 5

        let receiverController = try #require(
            container2.getController(name: "MockReceiverController") as? MockReceiverController,
            "Expected MockReceiverController in container2"
        )
        let emitterController = try #require(
            container1.getController(name: "MockEmitterController") as? MockEmitterController,
            "Expected MockEmitterController in container1"
        )

        // Subscribe to every type up front, before publishing anything. Each
        // subscription's topic is objectType-scoped, so there's no wire-level
        // reason they can't all be active at once, and setting them up in a
        // tight cancel-then-resubscribe loop instead raced the SDK's async
        // unsubscribe cleanup against the next iteration's subscribe: the
        // next subscription's ack could resolve before the previous one's
        // outstanding unsubscribe (a detached task, not awaited by this
        // caller) reached the broker, silently dropping the first events
        // published right after. See https://github.com/phynics/axoloty/issues/51.
        var loggers: [String: AdvertiseEventLogger] = [:]
        var watchTasks: [_Concurrency.Task<Void, Never>] = []
        for element in SensorThingsTests.SENSOR_THINGS_TYPES_SET {
            let logger = AdvertiseEventLogger()
            loggers[element] = logger
            try watchTasks.append(
                await receiverController.watchForAdvertiseEvents(logger: logger, objectType: element)
            )
        }

        for element in SensorThingsTests.SENSOR_THINGS_TYPES_SET {
            emitterController.publishAdvertiseEvents(count: eventCount, objectType: element)
        }

        for element in SensorThingsTests.SENSOR_THINGS_TYPES_SET {
            let logger = try #require(loggers[element])
            try await waitUntil(
                "\(eventCount) advertise events of type \(element)",
                timeout: .seconds(SensorThingsTests.TEST_TIMEOUT)
            ) {
                logger.count == eventCount && logger.eventData.count == eventCount
            }

            let expectedNames = Set((1 ... eventCount).map { "Advertised_\($0)" })
            let actualNames = Set(logger.eventData.map(\.object.name))
            #expect(actualNames == expectedNames)
        }

        for watchTask in watchTasks {
            watchTask.cancel()
            _ = await watchTask.value
        }

        container1.shutdown()
        container2.shutdown()
    }

    @Test
    func channel() async throws {
        let mqttClientOptions1 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: false)
        let controllerOptions1 = ControllerOptions(extra: ["name": "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController": controllerOptions1])
        let configuration1 = Configuration(common: nil,
                                           communication: communicationOptions1,
                                           controllers: controllersConfig1,
                                           databases: nil)
        let controllers1: [String: Controller.Type] = ["MockEmitterController": MockEmitterController.self]
        let components1 = Components(controllers: controllers1, objectTypes: [])
        let container1 = Container.resolve(components: components1, configuration: configuration1)

        let mqttClientOptions2 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions2 = CommunicationOptions(mqttClientOptions: mqttClientOptions2, shouldAutoStart: false)
        let configuration2 = Configuration(communication: communicationOptions2)
        let controllers2: [String: Controller.Type] = ["MockReceiverController": MockReceiverController.self]
        let components2 = Components(controllers: controllers2, objectTypes: [])
        let container2 = Container.resolve(components: components2, configuration: configuration2)

        try await withTimeout("container1 ready") { try await container1.startAndWaitUntilReady() }
        try await withTimeout("container2 ready") { try await container2.startAndWaitUntilReady() }

        let eventCount = 2
        let channelId = "42"

        guard let receiverController = container2.getController(name: "MockReceiverController") as? MockReceiverController else {
            Issue.record("Expected MockReceiverController in container2")
            return
        }
        guard let emitterController = container1.getController(name: "MockEmitterController") as? MockEmitterController else {
            Issue.record("Expected MockEmitterController in container1")
            return
        }

        let logger = ChannelEventLogger()

        // Awaiting this confirms the broker has acknowledged the subscription,
        // so publishing right after can't race a "long enough" fixed delay
        // (see https://github.com/phynics/axoloty/issues/51). Subscribing once
        // for the whole test (rather than per element) also avoids racing a
        // cancel's async unsubscribe cleanup against the next element's
        // resubscribe to the same channel topic.
        let watchTask = try await receiverController.watchForChannelEvents(logger: logger, channelId: channelId)

        for (index, element) in SensorThingsTests.SENSOR_THINGS_TYPES_SET.enumerated() {
            emitterController.publishChannelEvents(count: eventCount, objectType: element, channelId: channelId)

            let expectedTotal = (index + 1) * eventCount
            try await waitUntil(
                "\(expectedTotal) cumulative channel events after publishing \(element)",
                timeout: .seconds(SensorThingsTests.TEST_TIMEOUT)
            ) {
                logger.eventData.count >= expectedTotal
            }

            // MQTT delivery order across a fresh subscription isn't guaranteed to
            // match publish order (as advertise()'s matching set-based check above
            // already assumes), so verify the newly arrived slice by name set
            // rather than by array index. Object names encode only the
            // per-publish index, not the objectType, so every element
            // produces the same expected name set.
            let expectedNames = Set((1 ... eventCount).map { "Channeled_\($0)" })
            let actualNames = Set(logger.eventData.suffix(eventCount).compactMap { $0.object?.name })
            #expect(actualNames == expectedNames)
        }

        watchTask.cancel()
        _ = await watchTask.value

        container1.shutdown()
        container2.shutdown()
    }

    @Test
    func coatyTimeIntervalFormatting() {
        // Fixed UTC inputs so the test is deterministic and not wall-clock dependent.
        let interval = CoatyTimeInterval(start: 0, duration: 4_200_012)

        let withMillis = interval.toLocalIntervalIsoString(includeMillis: true)
        #expect(withMillis.hasPrefix("1970-01-01T00:00:00.000Z/PT4200S"))

        let withoutMillis = interval.toLocalIntervalIsoString(includeMillis: false)
        #expect(withoutMillis.hasPrefix("1970-01-01T00:00:00Z/PT4200S"))

        let zeroDuration = CoatyTimeInterval(start: 0, duration: 0)
        #expect(zeroDuration.toLocalIntervalIsoString(includeMillis: false).hasSuffix("/PT0S"))
    }
}
