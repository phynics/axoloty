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
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: true)
        let controllerOptions1 = ControllerOptions(extra: ["name": "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController": controllerOptions1])
        let configuration1 = Configuration(common: nil,
                                           communication: communicationOptions1,
                                           controllers: controllersConfig1,
                                           databases: nil)
        let controllers1: [String: Controller.Type] = ["MockEmitterController": MockEmitterController.self]
        let components1 = Components(controllers: controllers1, objectTypes: [])
        let container1 = Container.resolve(components: components1, configuration: configuration1)
        container1.communicationManager?.start()

        let mqttClientOptions2 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions2 = CommunicationOptions(mqttClientOptions: mqttClientOptions2, shouldAutoStart: true)
        let configuration2 = Configuration(communication: communicationOptions2)
        let controllers2: [String: Controller.Type] = ["MockReceiverController": MockReceiverController.self]
        let components2 = Components(controllers: controllers2, objectTypes: [])
        let container2 = Container.resolve(components: components2, configuration: configuration2)
        container2.communicationManager?.start()

        // Give the infrastructure time to start
        try await _Concurrency.Task.sleep(for: .seconds(4))

        let eventCount = 5
        let completion = DispatchGroup()
        let expectedFulfillments = SensorThingsTests.SENSOR_THINGS_TYPES_SET.count * (eventCount + 2)
        for _ in 0 ..< expectedFulfillments {
            completion.enter()
        }

        for element in SensorThingsTests.SENSOR_THINGS_TYPES_SET {
            let receiverController = try #require(
                container2.getController(name: "MockReceiverController") as? MockReceiverController,
                "Expected MockReceiverController in container2"
            )

            let logger = AdvertiseEventLogger()

            receiverController.watchForAdvertiseEvents(logger: logger, objectType: element)

            let emitterController = try #require(
                container1.getController(name: "MockEmitterController") as? MockEmitterController,
                "Expected MockEmitterController in container1"
            )

            let queue = DispatchQueue(label: "test.coaty.sensorThings")
            let delay: DispatchTimeInterval = .milliseconds(1500)
            queue.asyncAfter(deadline: .now() + delay) {
                _Concurrency.Task { @MainActor in
                    emitterController.publishAdvertiseEvents(count: eventCount, objectType: element)
                }

                // smaller delay does not always guarantee that all events will be received
                let delay2: DispatchTimeInterval = .seconds(4)

                queue.asyncAfter(deadline: .now() + delay2) {
                    if logger.count == eventCount {
                        completion.leave()
                    }
                    if logger.eventData.count == eventCount {
                        completion.leave()
                    }
                    let expectedNames = Set((1 ... eventCount).map { "Advertised_\($0)" })
                    let actualNames = Set(logger.eventData.map(\.object.name))
                    if actualNames == expectedNames {
                        for _ in 1 ... eventCount {
                            completion.leave()
                        }
                    } else {
                        Issue.record("Unexpected advertised object names: \(actualNames)")
                    }
                }
            }
        }

        let timeout = SensorThingsTests.TEST_TIMEOUT
        let result = await Self.awaitGroup(completion, timeout: .now() + TimeInterval(5 * timeout))
        container1.shutdown()
        container2.shutdown()
        try await _Concurrency.Task.sleep(for: .seconds(2))
        #expect(result == .success)
    }

    @Test

    func channel() async throws {
        let mqttClientOptions1 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: true)
        let controllerOptions1 = ControllerOptions(extra: ["name": "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController": controllerOptions1])
        let configuration1 = Configuration(common: nil,
                                           communication: communicationOptions1,
                                           controllers: controllersConfig1,
                                           databases: nil)
        let controllers1: [String: Controller.Type] = ["MockEmitterController": MockEmitterController.self]
        let components1 = Components(controllers: controllers1, objectTypes: [])
        let container1 = Container.resolve(components: components1, configuration: configuration1)
        container1.communicationManager?.start()

        let mqttClientOptions2 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions2 = CommunicationOptions(mqttClientOptions: mqttClientOptions2, shouldAutoStart: true)
        let configuration2 = Configuration(communication: communicationOptions2)
        let controllers2: [String: Controller.Type] = ["MockReceiverController": MockReceiverController.self]
        let components2 = Components(controllers: controllers2, objectTypes: [])
        let container2 = Container.resolve(components: components2, configuration: configuration2)
        container2.communicationManager?.start()

        // Give the infrastructure time to start
        try await _Concurrency.Task.sleep(for: .seconds(2))

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

        for element in SensorThingsTests.SENSOR_THINGS_TYPES_SET {
            let logger = ChannelEventLogger()

            // Awaiting this confirms the broker has acknowledged the subscription,
            // so publishing right after can't race a "long enough" fixed delay
            // (see https://github.com/phynics/axoloty/issues/51).
            let watchTask = try await receiverController.watchForChannelEvents(logger: logger, channelId: channelId)

            emitterController.publishChannelEvents(count: eventCount, objectType: element, channelId: channelId)

            let deadline = Date().addingTimeInterval(TimeInterval(SensorThingsTests.TEST_TIMEOUT))
            while logger.eventData.count < eventCount && Date() < deadline {
                try await _Concurrency.Task.sleep(for: .milliseconds(100))
            }

            // MQTT delivery order across a fresh subscription isn't guaranteed to
            // match publish order (as advertise()'s matching set-based check above
            // already assumes), so verify by name set rather than by array index.
            let expectedNames = Set((1 ... eventCount).map { "Channeled_\($0)" })
            let actualNames = Set(logger.eventData.compactMap { $0.object?.name })
            #expect(actualNames == expectedNames)

            watchTask.cancel()
            _ = await watchTask.value
        }

        container1.shutdown()
        container2.shutdown()
        try await _Concurrency.Task.sleep(for: .seconds(2))
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

    /// Waits for a `DispatchGroup` off the cooperative pool. Apple toolchains
    /// mark `DispatchGroup.wait` unavailable from async contexts, so route it
    /// through a continuation on a global queue.
    private static func awaitGroup(
        _ group: DispatchGroup, timeout: DispatchTime
    ) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: group.wait(timeout: timeout))
            }
        }
    }
}
