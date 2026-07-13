//  Copyright (c) 2021 Siemens AG. Licensed under the MIT License.
//
//  DecentralizedLoggingTest.swift
//  CoatySwift

import Foundation
import Testing
import CoatySwift

@Suite
struct DecentralizedLoggingTest {

    /// NOTE: Please make sure that a MQTT broker is running on localhost on port 1883 before running.
    @Test
    func testExample() throws {
        let components1 = Components(controllers: ["LogCreateorController": LogCreatorController.self],
                                     objectTypes: [])
        let communication1 = CommunicationOptions(namespace: "Logging Test",
                                                 mqttClientOptions: MQTTClientOptions(host: "localhost",
                                                                                      port: UInt16(1883)),
                                                 shouldAutoStart: false)
        let configuration1 = Configuration(communication: communication1)
        let coatyContainer1 = Container.resolve(components: components1,
                                                configuration: configuration1)

        let components2 = Components(controllers: ["LogReceiverController": LogReceiverController.self],
                                     objectTypes: [])
        let communication2 = CommunicationOptions(namespace: "Logging Test",
                                                 mqttClientOptions: MQTTClientOptions(host: "localhost",
                                                                                      port: UInt16(1883)),
                                                 shouldAutoStart: false)
        let configuration2 = Configuration(communication: communication2)
        let coatyContainer2 = Container.resolve(components: components2,
                                                configuration: configuration2)

        // Bring the receiver online and subscribe it before the creator flushes
        // its deferred publications. MQTT does not retain these log events, so
        // starting the publisher first introduces a subscription race.
        let receiverOnline = DispatchSemaphore(value: 0)
        let stateSubscription = coatyContainer2.communicationManager?
            .observeCommunicationState()
            .filter { $0 == .online }
            .take(1)
            .subscribe(onNext: { _ in receiverOnline.signal() })
        coatyContainer2.communicationManager?.start()
        #expect(receiverOnline.wait(timeout: .now() + 5) == .success)
        stateSubscription?.dispose()
        Thread.sleep(forTimeInterval: 0.25)
        coatyContainer1.communicationManager?.start()

        guard let receiverController = coatyContainer2.getController(name: "LogReceiverController") as? LogReceiverController else {
            return
        }

        // Introduce a 5 seconds waiting time to give the infrastructure time to log everything.
        Thread.sleep(forTimeInterval: 5.0)
        do {
            // Check if all log events have been received.
            // The loop can be used to inspect individual log objects when debugging.
//            receiverController.logStorage.forEach { log in
//                print(log.logTags)
//                print(log.logLabels)
//                print(log.logHost)
//            }
            #expect(receiverController.logStorage.count == 50)
        }

        // Shutdown both containers explicitly
        coatyContainer1.shutdown()
        coatyContainer2.shutdown()
    }
}

class LogCreatorController: Controller {
    override func extendLogObject(log: Log) {
        log.logLabels = [
            "nonce": Int.random(in: 0...10000)
        ]
    }

    override func onCommunicationManagerStarting() {
        self.publishMultipleLogs()
    }

    /// Publishes 50 log objects in total
    private func publishMultipleLogs() {
        for _ in 0...9 {
            self.logInfo(message: "Info Log", tags: ["tag1", "tag2"])
            self.logDebug(message: "Debug Log", tags: ["tag1", "tag2"])
            self.logWarning(message: "Warning Log", tags: ["tag1", "tag2"])
            self.logError(error: CoatySwiftError.RuntimeError("Random error"), message: "Error Log", tags: ["tag1", "tag2"])
            self.logFatal(error: CoatySwiftError.RuntimeError("Random fatal error"), message: "Fatal Log", tags: ["tag1", "tag2"])
        }
    }
}

class LogReceiverController: Controller {
    public var logStorage: [Log] = []

    override func onInit() {
        self.logStorage = .init()
    }

    override func onCommunicationManagerStarting() {
        _ = self.communicationManager.observeAdvertise(withCoreType: .Log).subscribe(onNext: { event in
            guard let logObject = event.data.object as? Log else {
                fatalError("Expected a Log object, but got something different. Stopping")
            }
            self.logStorage.append(logObject)
        })
    }
}
