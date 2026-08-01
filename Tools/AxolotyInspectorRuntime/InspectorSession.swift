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
        let outcome: ConnectOutcome = try await withTaskGroup(of: ConnectOutcome.self) { group in
            group.addTask { [self] in
                do {
                    try await self.container.startAndWaitUntilReady()
                    return .connected
                } catch let error as AxolotyError {
                    return .failed(error.userFriendlyMessage)
                } catch {
                    return .failed(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: self.connectTimeout)
                return .timedOut
            }

            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch outcome {
        case .connected:
            return
        case .timedOut:
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
