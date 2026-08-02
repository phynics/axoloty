// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import Foundation

/// The injectable session boundary for the inspector application.
///
/// Tests provide a fake implementation; production code uses
/// ``AxolotyInspectorSession``.
@MainActor
public protocol InspectorSession {
    /// Starts the connection and waits until the broker is ready and
    /// desired subscriptions are activated.
    func connect() async throws
    /// Returns the namespace-wide Advertise event stream.
    func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot>
    /// Returns the Deadvertise event stream.
    func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot>
    /// Publishes a Discover event and returns the correlated Resolve
    /// response stream.
    func discover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot>
    /// Stops the session and disconnects from the broker.
    func stop()
}

/// A concrete ``InspectorSession`` backed by Axoloty's ``CommunicationManager``
/// and ``Container``.
///
/// The session establishes event streams before connecting so that
/// subscriptions are desired when the manager comes online. This avoids
/// the subscription race where events arrive before the topic subscription
/// is active.
@MainActor
public final class AxolotyInspectorSession: InspectorSession {
    private let container: Container
    private let manager: CommunicationManager
    private let connectTimeout: Duration

    /// Creates a session from the given connection configuration.
    public init(configuration: InspectorConnectionConfiguration) throws {
        let mqttOptions = MQTTClientOptions(
            host: configuration.host,
            port: configuration.port,
            enableSSL: configuration.usesTLS,
            shouldTryMDNSDiscovery: false,
            username: configuration.username,
            password: configuration.password,
            autoReconnect: true,
            autoReconnectTimeInterval: 1,
            qos: 0,
            shouldLog: false
        )
        let commOptions = CommunicationOptions(
            namespace: configuration.namespace,
            shouldEnableCrossNamespacing: false,
            mqttClientOptions: mqttOptions,
            shouldAutoStart: false
        )
        let resolved = try Container.resolve(
            components: Components(controllers: [:], objectTypes: []),
            configuration: Configuration(communication: commOptions)
        )
        self.container = resolved
        self.manager = resolved.communicationManager!
        self.connectTimeout = configuration.connectTimeout
    }

    public func connect() async throws {
        let (outcomes, continuation) = AsyncStream.makeStream(of: ConnectOutcome.self)
        let connectionTask = Task { [container] in
            do {
                try await container.startAndWaitUntilReady()
                continuation.yield(.connected)
            } catch let error as AxolotyError {
                continuation.yield(.failed(error.userFriendlyMessage))
            } catch {
                continuation.yield(.failed(String(describing: error)))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: self.connectTimeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.timedOut)
        }
        defer {
            continuation.finish()
            connectionTask.cancel()
            timeoutTask.cancel()
        }

        var iterator = outcomes.makeAsyncIterator()
        guard let outcome = await iterator.next() else {
            throw InspectorError.connectionUnavailable(reason: "connection attempt ended without an outcome")
        }

        switch outcome {
        case .connected:
            return
        case .timedOut:
            container.shutdown()
            throw InspectorError.connectionUnavailable(
                reason: "connect timeout after \(connectTimeout)"
            )
        case let .failed(message):
            throw InspectorError.connectionUnavailable(reason: message)
        }
    }

    public func advertiseEvents() async -> AsyncStream<AdvertiseEventSnapshot> {
        await manager.observeAdvertiseStream()
    }

    public func deadvertiseEvents() async -> AsyncStream<DeadvertiseEventSnapshot> {
        await manager.observeDeadvertiseStream()
    }

    public func discover(_ event: DiscoverEvent) async -> AsyncStream<ResponseEventSnapshot> {
        await manager.publishDiscover(event)
    }

    public func stop() {
        container.shutdown()
    }
}

private enum ConnectOutcome: Sendable {
    case connected
    case timedOut
    case failed(String)
}
