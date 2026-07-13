// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CoatySwift
import Darwin
import Foundation
import RxSwift

private let pinnedCommit = "20a97b29832758fb771ac79fd5f7ae36cff69403"
private let namespace = "wire-compat-v1"
private let advertisedObjectId = "00000000-0000-4000-8000-000000000101"

private struct Arguments {
    let brokerHost: String
    let brokerPort: UInt16
    let scenario: String
    let sourceCommit: String

    init(_ values: [String]) throws {
        var options = [String: String]()
        var index = 1
        while index < values.count {
            guard index + 1 < values.count, values[index].hasPrefix("--") else {
                throw RunnerError.usage("arguments must be --name value pairs")
            }
            options[String(values[index].dropFirst(2))] = values[index + 1]
            index += 2
        }

        guard let host = options["broker-host"], !host.isEmpty,
              let portText = options["broker-port"], let port = UInt16(portText),
              let scenario = options["scenario"],
              let sourceCommit = options["source-commit"] else {
            throw RunnerError.usage("required: --broker-host HOST --broker-port PORT --scenario advertise --source-commit COMMIT")
        }
        self.brokerHost = host
        self.brokerPort = port
        self.scenario = scenario
        self.sourceCommit = sourceCommit
    }
}

private enum RunnerError: Error, CustomStringConvertible {
    case usage(String)
    case invalidPin(String)
    case unsupportedScenario(String)
    case timeout

    var description: String {
        switch self {
        case .usage(let message), .invalidPin(let message): return message
        case .unsupportedScenario(let scenario): return "unsupported scenario: \(scenario)"
        case .timeout: return "timed out waiting for the legacy client to connect"
        }
    }
}

private func run(_ arguments: Arguments) throws {
    guard arguments.sourceCommit == pinnedCommit else {
        throw RunnerError.invalidPin("requested source commit does not match compiled pin \(pinnedCommit)")
    }
    guard arguments.scenario == "advertise" else {
        throw RunnerError.unsupportedScenario(arguments.scenario)
    }

    let mqtt = MQTTClientOptions(host: arguments.brokerHost, port: arguments.brokerPort)
    let communication = CommunicationOptions(
        namespace: namespace,
        mqttClientOptions: mqtt,
        shouldAutoStart: false
    )
    let configuration = Configuration(communication: communication)
    let components = Components(controllers: [:], objectTypes: [])
    let container = Container.resolve(components: components, configuration: configuration)
    guard let manager = container.communicationManager else {
        throw RunnerError.usage("legacy container did not create a communication manager")
    }

    let online = DispatchSemaphore(value: 0)
    let subscription = manager.observeCommunicationState()
        .filter { $0 == .online }
        .take(1)
        .subscribe(onNext: { _ in online.signal() })

    print("{\"state\":\"ready\",\"scenario\":\"advertise\"}")
    manager.start()
    guard online.wait(timeout: .now() + 15) == .success else {
        subscription.dispose()
        manager.stop()
        throw RunnerError.timeout
    }

    let object = CoatyObject(
        coreType: .CoatyObject,
        objectType: "org.axoloty.wire.ReferenceObject",
        objectId: CoatyUUID(uuidString: advertisedObjectId)!,
        name: "wire-compat-reference"
    )
    try manager.publishAdvertise(AdvertiseEvent.with(object: object))
    print("{\"state\":\"published\",\"scenario\":\"advertise\",\"objectId\":\"\(advertisedObjectId)\"}")
    Thread.sleep(forTimeInterval: 1.0)
    subscription.dispose()
    manager.stop()
    print("{\"state\":\"done\",\"scenario\":\"advertise\"}")
}

do {
    try run(Arguments(CommandLine.arguments))
} catch {
    fputs("legacy scenario runner: \(error)\n", stderr)
    exit(2)
}
