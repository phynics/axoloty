// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import CoatySwift
import Darwin
import Foundation
import RxSwift

private let pinnedCommit = "20a97b29832758fb771ac79fd5f7ae36cff69403"
private let namespace = "wire-compat-v1"
private let referenceObjectType = "org.axoloty.wire.ReferenceObject"
private let referenceObjectId = "00000000-0000-4000-8000-000000000101"
// The requester and responder identity UUIDs must differ within their first
// 18 hex digits (dashes stripped): CoatySwift derives each client's MQTT
// ClientID from exactly that prefix (see `initializeMQTTClientId`), and two
// clients sharing an MQTT ClientID cause the broker to repeatedly disconnect
// whichever client connected first every time the other (re)connects. IDs
// that only differed in their final digits (as in an earlier version of this
// file) collided and produced an endless advertise/deadvertise reconnect
// loop instead of a stable Discover/Resolve exchange.
private let requesterIdentityId = "00000000-0000-4000-8000-000000000201"
private let responderIdentityId = "00000000-0000-4000-9000-000000000202"
private let settleInterval: TimeInterval = 1
private let resolveTimeout: TimeInterval = 5
private let onlineTimeout: TimeInterval = 15

/// Blocks the calling thread for `interval` while still servicing the main
/// run loop in short slices.
///
/// CocoaMQTT (used by pinned CoatySwift 2.4.0) dispatches its socket
/// delegate callbacks onto the main dispatch queue, which is only drained by
/// spinning the main run loop. A plain `Thread.sleep` starves that queue, so
/// the MQTT CONNECT/CONNACK handshake and every subsequent PUBLISH
/// confirmation would never actually run, silently dropping every
/// publication despite the process reporting `"state":"done"`. This helper
/// keeps the process printing correct state transitions honest by actually
/// letting the network stack make progress while it waits.
private func runLoopSleep(_ interval: TimeInterval) {
    let deadline = Date().addingTimeInterval(interval)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: min(Date().addingTimeInterval(0.05), deadline))
    }
}

/// Waits for `semaphore` while still servicing the main run loop, or returns
/// `false` once `timeout` elapses. See `runLoopSleep` for why a bare
/// `DispatchSemaphore.wait` cannot be used here.
private func runLoopWait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if semaphore.wait(timeout: .now()) == .success {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return semaphore.wait(timeout: .now()) == .success
}

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
              let sourceCommit = options["source-commit"]
        else {
            throw RunnerError.usage("required: --broker-host HOST --broker-port PORT --scenario advertise|deadvertise|discover-resolve --source-commit COMMIT")
        }
        brokerHost = host
        brokerPort = port
        self.scenario = scenario
        self.sourceCommit = sourceCommit
    }
}

private enum RunnerError: Error, CustomStringConvertible {
    case usage(String)
    case invalidPin(String)
    case unsupportedScenario(String)
    case readinessTimeout
    case onlineTimeout
    case timeout

    var description: String {
        switch self {
        case let .usage(message), let .invalidPin(message): return message
        case let .unsupportedScenario(scenario): return "unsupported scenario: \(scenario)"
        case .readinessTimeout: return "timed out waiting for responder Identity subscription evidence"
        case .onlineTimeout: return "timed out waiting for communication manager to go online"
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

/// Waits for `manager` to report `.online`, or throws once `onlineTimeout`
/// elapses.
///
/// Restores the guard dropped when RxSwift removal replaced this wait with a
/// blind 1s sleep after `start()`: publishing before the broker connection is
/// actually up silently drops the publication despite the process reporting
/// success. See issue #61.
private func waitUntilOnline(_ manager: CommunicationManager) throws {
    let online = DispatchSemaphore(value: 0)
    let subscription = manager.observeCommunicationState()
        .filter { $0 == .online }
        .take(1)
        .subscribe(onNext: { _ in online.signal() })
    defer { subscription.dispose() }

    guard runLoopWait(online, timeout: onlineTimeout) else {
        throw RunnerError.onlineTimeout
    }
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
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }
    try publish(manager)
    report("published", scenario: arguments.scenario, details: ",\"objectId\":\"\(referenceObjectId)\"")
    runLoopSleep(settleInterval)
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
    guard runLoopWait(responderIdentityObserved, timeout: resolveTimeout) else {
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

    guard runLoopWait(resolveReceived, timeout: resolveTimeout) else {
        discoverSubscription.dispose()
        resolveSubscription.dispose()
        requesterManager.stop()
        responderManager.stop()
        throw RunnerError.timeout
    }

    discoverSubscription.dispose()
    resolveSubscription.dispose()
    runLoopSleep(settleInterval)
    requesterManager.stop()
    responderManager.stop()
}

// MARK: - Consumer scenarios (Modern → legacy)

/// Long-lived consumer that subscribes to Advertise events for the reference
/// object type, decodes the first one it receives, and reports the semantic
/// fields. Axoloty acts as the producer.
private func runConsumeAdvertise(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: requesterIdentityId,
        identityName: "coatyswift-wire-consumer"
    )
    let manager = try communicationManager(for: container)
    let received = DispatchSemaphore(value: 0)

    let subscription = manager.observeAdvertise(withObjectType: referenceObjectType)
        .subscribe(onNext: { event in
            let obj = event.data.object
            report("observed-advertise", scenario: arguments.scenario,
                   details: ",\"objectType\":\"\(obj.objectType)\",\"objectId\":\"\(obj.objectId.string)\"")
            received.signal()
        })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(received, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
}

/// Long-lived consumer that subscribes to Deadvertise events, decodes the
/// first one, and reports the object IDs. Axoloty acts as the producer.
private func runConsumeDeadvertise(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: requesterIdentityId,
        identityName: "coatyswift-wire-consumer"
    )
    let manager = try communicationManager(for: container)
    let received = DispatchSemaphore(value: 0)

    let subscription = manager.observeDeadvertise()
        .subscribe(onNext: { event in
            let ids = event.data.objectIds.map { $0.string }
            report("observed-deadvertise", scenario: arguments.scenario,
                   details: ",\"objectIds\":\(ids)")
            received.signal()
        })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(received, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
}

/// Long-lived consumer that subscribes to Channel events on a deterministic
/// channel ID, decodes the first one, and reports the message. Axoloty acts
/// as the producer.
private func runConsumeChannel(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: requesterIdentityId,
        identityName: "coatyswift-wire-consumer"
    )
    let manager = try communicationManager(for: container)
    let received = DispatchSemaphore(value: 0)

    let subscription = manager.observeChannel(channelId: 42)
        .subscribe(onNext: { event in
            report("observed-channel", scenario: arguments.scenario,
                   details: ",\"channelId\":\(event.data.channelId)")
            received.signal()
        })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(received, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
}

/// Legacy responder that subscribes to Discover events for the reference
/// object type and publishes a correlated Resolve. Axoloty acts as the
/// Discover requester.
private func runRespondDiscover(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: responderIdentityId,
        identityName: "coatyswift-wire-responder"
    )
    let manager = try communicationManager(for: container)
    let responded = DispatchSemaphore(value: 0)

    let subscription = manager.observeDiscover().subscribe(onNext: { event in
        guard event.data.isObjectTypeCompatible(objectType: referenceObjectType) else {
            return
        }
        report("observed-discover", scenario: arguments.scenario)
        event.resolve(resolveEvent: ResolveEvent.with(
            object: referenceObject(),
            privateData: ["reference": "coatyswift-2.4.0"]
        ))
        responded.signal()
    })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(responded, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
}

/// Legacy responder that subscribes to Query events for the reference object
/// type and publishes a correlated Retrieve. Axoloty acts as the Query
/// requester.
private func runRespondQuery(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: responderIdentityId,
        identityName: "coatyswift-wire-responder"
    )
    let manager = try communicationManager(for: container)
    let responded = DispatchSemaphore(value: 0)

    let subscription = manager.observeQuery().subscribe(onNext: { event in
        guard event.data.objectTypes?.contains(referenceObjectType) == true else {
            return
        }
        report("observed-query", scenario: arguments.scenario)
        event.retrieve(retrieveEvent: RetrieveEvent.with(
            object: referenceObject()
        ))
        responded.signal()
    })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(responded, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
}

/// Legacy responder that subscribes to Call events for a deterministic
/// operation and publishes a correlated Return. Axoloty acts as the Call
/// initiator.
private func runRespondCall(_ arguments: Arguments) throws {
    let container = makeContainer(
        arguments: arguments,
        identityId: responderIdentityId,
        identityName: "coatyswift-wire-responder"
    )
    let manager = try communicationManager(for: container)
    let responded = DispatchSemaphore(value: 0)
    let operationType = "org.axoloty.wire.ReferenceOperation"

    let subscription = manager.observeCall().subscribe(onNext: { event in
        guard event.data.operationType == operationType else {
            return
        }
        report("observed-call", scenario: arguments.scenario,
               details: ",\"operationType\":\"\(operationType)\"")
        event.return(returnEvent: ReturnEvent.with(
            result: ["status": "ok", "responder": "coatyswift-2.4.0"]
        ))
        responded.signal()
    })
    defer { subscription.dispose() }

    report("ready", scenario: arguments.scenario)
    manager.start()
    do {
        try waitUntilOnline(manager)
    } catch {
        manager.stop()
        throw error
    }

    guard runLoopWait(responded, timeout: resolveTimeout) else {
        manager.stop()
        throw RunnerError.timeout
    }

    runLoopSleep(settleInterval)
    manager.stop()
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
    // Consumer scenarios: legacy CoatySwift subscribes to events an Axoloty
    // producer publishes, decodes them, and reports the semantic fields it
    // observed. These enable the Modern → legacy matrix direction.
    case "consume-advertise":
        try runConsumeAdvertise(arguments)
    case "consume-deadvertise":
        try runConsumeDeadvertise(arguments)
    case "consume-channel":
        try runConsumeChannel(arguments)
    case "respond-discover":
        try runRespondDiscover(arguments)
    case "respond-query":
        try runRespondQuery(arguments)
    case "respond-call":
        try runRespondCall(arguments)
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
