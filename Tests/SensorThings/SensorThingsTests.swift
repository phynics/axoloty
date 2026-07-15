//  Copyright (c) 2020 Siemens AG. Licensed under the MIT License.
//
//  SensorThingsTests.swift
//  Axoloty

import Testing
import Foundation
import Axoloty
import RxSwift

/// NOTE: This test case sometimes fails to run because of some problems related to thread scheduling
/// If possible run these tests against a physical device (e.g. iPhone), instead of Simulator.
/// Please also note that test results are also often influenced by the current stress on the CPU.

// MARK: - Communication tests.
@Suite
struct SensorThingsTests {
    static let TEST_TIMEOUT = 10

    static let SENSOR_THINGS_TYPES_SET = [
        SensorThingsTypes.OBJECT_TYPE_FEATURE_OF_INTEREST,
        SensorThingsTypes.OBJECT_TYPE_OBSERVATION,
        SensorThingsTypes.OBJECT_TYPE_SENSOR,
        SensorThingsTypes.OBJECT_TYPE_THING
    ]

    // MARK: - Test methods.
    @Test
    func testAdvertise() throws {
        let mqttClientOptions1 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: true)
        let controllerOptions1 = ControllerOptions(extra: ["name" : "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController" : controllerOptions1])
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
        sleep(4)

        let eventCount = 5
        let completion = DispatchGroup()
        let expectedFulfillments = SensorThingsTests.SENSOR_THINGS_TYPES_SET.count * (eventCount + 2)
        for _ in 0..<expectedFulfillments { completion.enter() }

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

            let queue = DispatchQueue.init(label: "test.coaty.sensorThings")
            let delay: DispatchTimeInterval = .milliseconds(1500)
            queue.asyncAfter(deadline: .now() + delay) {
                emitterController.publishAdvertiseEvents(count: eventCount, objectType: element)

                // smaller delay does not always guarantee that all events will be received
                let delay2: DispatchTimeInterval = .seconds(4)

                queue.asyncAfter(deadline: .now() + delay2) {
                    if logger.count == eventCount {
                        completion.leave()
                    }
                    if logger.eventData.count == eventCount {
                        completion.leave()
                    }
                    for i in 1...eventCount {
                        if i > logger.count {
                            Issue.record("Expected \(eventCount) advertise events, got \(logger.count)")
                            return
                        }
                        if logger.eventData[i-1].object.name == "Advertised_\(i)" {
                            completion.leave()
                        } else {
                            Issue.record("Unexpected object name \(logger.eventData[i-1].object.name) at index \(i)")
                            return
                        }
                    }
                }
            }
        }

        let result = completion.wait(timeout: .now() + TimeInterval(5 * SensorThingsTests.TEST_TIMEOUT))
        container1.shutdown()
        container2.shutdown()
        sleep(2)
        #expect(result == .success)
    }

    @Test

    func testChannel() throws {
        let mqttClientOptions1 = MQTTClientOptions(host: "127.0.0.1", port: UInt16(1883))
        let communicationOptions1 = CommunicationOptions(mqttClientOptions: mqttClientOptions1, shouldAutoStart: true)
        let controllerOptions1 = ControllerOptions(extra: ["name" : "MockEmitterController1", "responseDelay": 1000])
        let controllersConfig1 = ControllerConfig(controllerOptions: ["MockEmitterController" : controllerOptions1])
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
        sleep(2)

        let eventCount = 2
        let completion = DispatchGroup()
        let expectedFulfillments = SensorThingsTests.SENSOR_THINGS_TYPES_SET.count * (eventCount + 2)
        for _ in 0..<expectedFulfillments { completion.enter() }

        let queue = DispatchQueue.init(label: "test.coaty.sensorThings", qos: .userInitiated)

        let disposableBox = SendableBox<Disposable?>(nil)
        let testFunctionBox = SendableBox<(([String], Int) -> Void)?>(nil)

        let testFunction: ([String], Int) -> Void = { elementArray, index in
            if index == elementArray.count {
                return
            }
            let element = elementArray[index]
            let logger = ChannelEventLogger()
            let channelId = "42"

            guard let receiverController = container2.getController(name: "MockReceiverController") as? MockReceiverController else {
                Issue.record("Expected MockReceiverController in container2")
                return
            }
            guard let emitterController = container1.getController(name: "MockEmitterController") as? MockEmitterController else {
                Issue.record("Expected MockEmitterController in container1")
                return
            }

            queue.async {
                disposableBox.value = receiverController.watchForChannelEvents(logger: logger, channelId: channelId)
            }

            let delay: DispatchTimeInterval = .seconds(6)
            queue.asyncAfter(deadline: .now() + delay) {
                emitterController.publishChannelEvents(count: eventCount, objectType: element, channelId: channelId)

                let delay2: DispatchTimeInterval = .seconds(6)

                queue.asyncAfter(deadline: .now() + delay2) {
                    if logger.count == eventCount {
                        completion.leave()
                    }
                    if logger.eventData.count == eventCount {
                        completion.leave()
                    }
                    for i in 1...eventCount {
                        if i-1 < logger.eventData.count, let object = logger.eventData[i-1].object, object.name == "Channeled_\(i)" {
                            completion.leave()
                        } else {
                            Issue.record("Expected Channeled_\(i) at index \(i)")
                            return
                        }
                    }

                    disposableBox.value?.dispose()
                    testFunctionBox.value?(elementArray, index+1)
                }
            }
        }
        testFunctionBox.value = testFunction

        let copy = SensorThingsTests.SENSOR_THINGS_TYPES_SET
        testFunction(copy, 0)

        let result = completion.wait(timeout: .now() + TimeInterval(15 * SensorThingsTests.TEST_TIMEOUT))
        container1.shutdown()
        container2.shutdown()
        sleep(2)
        #expect(result == .success)
    }

    @Test
    func testCoatyTimeIntervalFormatting() throws {
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

private final class SendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
