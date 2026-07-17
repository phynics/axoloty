//  Copyright (c) 2021 Siemens AG. Licensed under the MIT License.
//
//  DecentralizedLoggingTest.swift
//  Axoloty

import Axoloty
import Foundation
import Testing

@MainActor
struct DecentralizedLoggingTest {
    /// NOTE: Please make sure that a MQTT broker is running on localhost on port 1883 before running.
    @Test
    func logEventsAreReceived() async throws {
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

        let receiverController = try #require(
            coatyContainer2.getController(name: "LogReceiverController") as? LogReceiverController,
            "Expected LogReceiverController in coatyContainer2"
        )

        try await withTimeout("container2 ready") { try await coatyContainer2.startAndWaitUntilReady() }
        try await withTimeout("container1 ready") { try await coatyContainer1.startAndWaitUntilReady() }

        try await waitUntil("50 received log snapshots", timeout: .seconds(5)) {
            await receiverController.logStorage.count == 50
        }
        #expect(await receiverController.logStorage.count == 50)

        // Shutdown both containers explicitly
        coatyContainer1.shutdown()
        coatyContainer2.shutdown()
    }
}

class LogCreatorController: Controller {
    override func extendLogObject(log: Log) {
        log.logLabels = [
            "nonce": Int.random(in: 0 ... 10000),
        ]
    }

    override func onCommunicationManagerReady() async {
        publishMultipleLogs()
    }

    /// Publishes 50 log objects in total
    private func publishMultipleLogs() {
        for _ in 0 ... 9 {
            logInfo(message: "Info Log", tags: ["tag1", "tag2"])
            logDebug(message: "Debug Log", tags: ["tag1", "tag2"])
            logWarning(message: "Warning Log", tags: ["tag1", "tag2"])
            logError(error: AxolotyError.invalidArgument(argument: "test", reason: "Random error"), message: "Error Log", tags: ["tag1", "tag2"])
            logFatal(error: AxolotyError.invalidArgument(argument: "test", reason: "Random fatal error"), message: "Fatal Log", tags: ["tag1", "tag2"])
        }
    }
}

class LogReceiverController: Controller {
    fileprivate let logStorage = SnapshotStore()
    private var consumptionTask: _Concurrency.Task<Void, Never>?

    override func prepareForCommunication() async {
        let stream = await communicationManager.observeAdvertiseStream(withCoreType: .Log)
        let storage = logStorage
        consumptionTask = _Concurrency.Task {
            var iterator = stream.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                await storage.append(snapshot)
            }
        }
    }

    override func onCommunicationManagerStopping() {
        consumptionTask?.cancel()
        consumptionTask = nil
        super.onCommunicationManagerStopping()
    }
}

private actor SnapshotStore {
    private var snapshots: [AdvertiseEventSnapshot] = []

    func append(_ snapshot: AdvertiseEventSnapshot) {
        snapshots.append(snapshot)
    }

    var count: Int {
        snapshots.count
    }
}
