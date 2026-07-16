// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CoatySwift
import Darwin
import Foundation

private let pinnedCommit = "20a97b29832758fb771ac79fd5f7ae36cff69403"
private let namespace = "wire-compat-v1"
private let referenceObjectType = "org.axoloty.wire.ReferenceObject"
private let referenceObjectId = "00000000-0000-4000-8000-000000000101"
private let requesterIdentityId = "00000000-0000-4000-8000-000000000201"
private let responderIdentityId = "00000000-0000-4000-8000-000000000202"
private let settleInterval: TimeInterval = 1
private let resolveTimeout: TimeInterval = 5

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
            throw RunnerError.usage("required: --broker-host HOST --broker-port PORT --scenario advertise|deadvertise|discover-resolve --source-commit COMMIT")
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
    case readinessTimeout
    case timeout

    var description: String {
        switch self {
        case .usage(let message), .invalidPin(let message): return message
        case .unsupportedScenario(let scenario): return "unsupported scenario: \(scenario)"
        case .readinessTimeout: return "timed out waiting for responder Identity subscription evidence"
        case .timeout: return "timed out waiting for deterministic Resolve"
        }
    }
}

private func referenceObject() -> CoatyObject {
    CoatyObject(
        coreType: .CoatyObject,
        objectType: referenceObjectType,
        objectId: CoatyUUID(uuidString: referenceObjectId)!,
        name: "wire-compat-reference"
    )
}

private func makeContainer(arguments: Arguments, identityId: String, identityName: String) -> Container {
    let mqtt = MQTTClientOptions(host: arguments.brokerHost, port: arguments.brokerPort)
    let communication = CommunicationOptions(
        namespace: namespace,
        mqttClientOptions: mqtt,
        shouldAutoStart: false
    )
    let common = CommonOptions(agentIdentity: [
        "objectId": CoatyUUID(uuidString: identityId)!,
        "name": identityName,
    ])
    let configuration = Configuration(common: common, communication: communication)
    let components = Components(controllers: [:], objectTypes: [])
    return Container.resolve(components: components, configuration: configuration)
}

private func communicationManager(for container: Container) throws -> CommunicationManager {
    guard let manager = container.communicationManager else {
        throw RunnerError.usage("legacy container did not create a communication manager")
    }
    return manager
}

private func report(_ state: String, scenario: String, details: String = "") {
    print("{\"state\":\"\(state)\",\"scenario\":\"\(scenario)\"\(details)}")
}

private func runOneWay(_ arguments: Arguments, publish: (CommunicationManager) throws -> Void) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: requesterIdentityId,
        identityName: "coatyswift-wire-reference"
    )
    let manager = try communicationManager(for: container)
    report("ready", scenario: arguments.scenario)
    manager.start()
    try publish(manager)
    report("published", scenario: arguments.scenario, details: ",\"objectId\":\"\(referenceObjectId)\"")
    Thread.sleep(forTimeInterval: settleInterval)
    manager.stop()
}

private func runDiscoverResolve(_ arguments: Arguments) throws {
    let requester = makeContainer(
        arguments: arguments,
        identityId: requesterIdentityId,
        identityName: "coatyswift-wire-requester"
    )
    let responder = makeContainer(
        arguments: arguments,
        identityId: responderIdentityId,
        identityName: "coatyswift-wire-responder"
    )
    let requesterManager = try communicationManager(for: requester)
    let responderManager = try communicationManager(for: responder)
    let responderIdentityObserved = DispatchSemaphore(value: 0)
    let resolveReceived = DispatchSemaphore(value: 0)

    let discoverSubscription = responderManager.observeDiscover().subscribe(onNext: { event in
        guard event.data.isObjectTypeCompatible(objectType: referenceObjectType) else {
            return
        }
        report("observed-discover", scenario: arguments.scenario)
        event.resolve(resolveEvent: ResolveEvent.with(
            object: referenceObject(),
            privateData: ["reference": "coatyswift-2.4.0"]
        ))
    })
    let identitySubscription = requesterManager
        .observeAdvertise(withCoreType: .Identity)
        .subscribe(onNext: { event in
            guard event.sourceId?.string == responderIdentityId else {
                return
            }
            responderIdentityObserved.signal()
        })
    report("ready", scenario: arguments.scenario)
    requesterManager.start()
    responderManager.start()
    guard responderIdentityObserved.wait(timeout: .now() + resolveTimeout) == .success else {
        discoverSubscription.dispose()
        identitySubscription.dispose()
        requesterManager.stop()
        responderManager.stop()
        throw RunnerError.readinessTimeout
    }
    identitySubscription.dispose()
    let resolveSubscription = requesterManager
        .publishDiscover(DiscoverEvent.with(objectTypes: [referenceObjectType]))
        .subscribe(onNext: { event in
            guard event.data.object?.objectId.string == referenceObjectId else {
                return
            }
            report("received-resolve", scenario: arguments.scenario, details: ",\"objectId\":\"\(referenceObjectId)\"")
            resolveReceived.signal()
        })
    report("published", scenario: arguments.scenario, details: ",\"objectType\":\"\(referenceObjectType)\"")

    guard resolveReceived.wait(timeout: .now() + resolveTimeout) == .success else {
        discoverSubscription.dispose()
        resolveSubscription.dispose()
        requesterManager.stop()
        responderManager.stop()
        throw RunnerError.timeout
    }

    discoverSubscription.dispose()
    resolveSubscription.dispose()
    Thread.sleep(forTimeInterval: settleInterval)
    requesterManager.stop()
    responderManager.stop()
}

private func run(_ arguments: Arguments) throws {
    guard arguments.sourceCommit == pinnedCommit else {
        throw RunnerError.invalidPin("requested source commit does not match compiled pin \(pinnedCommit)")
    }

    switch arguments.scenario {
    case "advertise":
        try runOneWay(arguments) { manager in
            try manager.publishAdvertise(AdvertiseEvent.with(object: referenceObject()))
        }
    case "deadvertise":
        try runOneWay(arguments) { manager in
            manager.publishDeadvertise(DeadvertiseEvent.with(objectIds: [referenceObject().objectId]))
        }
    case "discover-resolve":
        try runDiscoverResolve(arguments)
    default:
        throw RunnerError.unsupportedScenario(arguments.scenario)
    }

    report("done", scenario: arguments.scenario)
}

do {
    try run(Arguments(CommandLine.arguments))
} catch {
    fputs("legacy scenario runner: \(error)\n", stderr)
    exit(2)
}
