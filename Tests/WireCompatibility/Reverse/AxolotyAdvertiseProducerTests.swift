// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import XCTest
import CoatySwift

final class AxolotyAdvertiseProducerTests: XCTestCase {
    func testPublishesAdvertiseForCoatyJS() throws {
        guard ProcessInfo.processInfo.environment["WIRE_REVERSE_LIVE"] == "1" else {
            throw XCTSkip("Set WIRE_REVERSE_LIVE=1 through the reverse compatibility runner")
        }

        let environment = ProcessInfo.processInfo.environment
        let host = environment["WIRE_BROKER_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["WIRE_BROKER_PORT"] ?? "1883") ?? 1883
        let namespace = environment["WIRE_NAMESPACE"] ?? "wire-compat-v1"

        let communication = CommunicationOptions(
            namespace: namespace,
            mqttClientOptions: MQTTClientOptions(host: host, port: port),
            shouldAutoStart: false
        )
        let container = Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(communication: communication)
        )
        defer { container.shutdown() }

        guard let manager = container.communicationManager else {
            return XCTFail("Container did not resolve a communication manager")
        }

        let online = expectation(description: "Axoloty MQTT connection is online")
        let stateSubscription = manager.observeCommunicationState().subscribe(onNext: { state in
            if state == .online {
                online.fulfill()
            }
        })
        manager.start()
        wait(for: [online], timeout: 5.0)
        stateSubscription.dispose()

        let object = CoatyObject(
            coreType: .CoatyObject,
            objectType: "com.coaty.test.WireFixture",
            objectId: CoatyUUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "wire-fixture"
        )
        manager.publishAdvertise(try AdvertiseEvent.with(object: object))
        Thread.sleep(forTimeInterval: 0.5)
    }
}
