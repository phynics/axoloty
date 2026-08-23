// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyWire
import Foundation

/// The injectable session boundary for the inspector application.
@MainActor
public protocol InspectorSession {
    /// Starts the modern host runtime and waits for broker readiness.
    func connect() async throws
    /// Returns the current runtime transport state.
    func transportState() async -> InspectorTransportState
    /// Returns the namespace-wide Advertise stream.
    func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent>
    /// Returns the Deadvertise stream.
    func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent>
    /// Publishes one typed Discover operation and returns matching Resolve events.
    func discover(_ request: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent>
    /// Requests runtime shutdown.
    func stop()
}

/// Inspector adapter over the structured host runtime and MQTT binding.
///
/// The adapter owns no protocol state. It only decodes owned runtime event
/// values into the inspector's stable catalogue shapes.
@MainActor
public final class AxolotyInspectorSession: InspectorSession {
    private let runtime: AxolotyRuntime
    private let namespace: String
    private let advertiseStream: RuntimeEventStream
    private let deadvertiseStream: RuntimeEventStream
    private let resolveStream: RuntimeEventStream
    private var discoveryInFlight = false
    private var discoveryTask: Task<Void, Never>?
    private var discoveryCorrelation: UUID16?

    /// Creates a session from broker configuration.
    public init(configuration: InspectorConnectionConfiguration) throws {
        let capacities = try RuntimeCapacities(
            ingress: 64,
            dispatch: 64,
            handlers: 16,
            handlersInFlight: 16,
            stream: 64,
            eventStreams: 8
        )
        var definition = try RuntimeDefinition(
            namespace: configuration.namespace,
            sourceID: .zero,
            capacities: capacities
        )
        self.advertiseStream = try definition.registerEvents(
            matching: .family(.advertise),
            buffering: .dropOldest(capacity: 64)
        )
        self.deadvertiseStream = try definition.registerEvents(
            matching: .family(.deadvertise),
            buffering: .dropOldest(capacity: 64)
        )
        self.resolveStream = try definition.registerEvents(
            matching: .family(.resolve),
            buffering: .dropOldest(capacity: 64)
        )
        let sealed = try definition.seal()
        let binding = try MQTTBinding(configuration: MQTTBindingConfiguration(
            host: configuration.host,
            port: configuration.port,
            usesTLS: configuration.usesTLS,
            username: configuration.username,
            password: configuration.password,
            connectionTimeoutMS: UInt32(max(1, min(120_000, configuration.connectTimeout.millisecondsValue)))
        ))
        self.runtime = AxolotyRuntime(definition: sealed, transport: binding)
        self.namespace = configuration.namespace
    }

    public func connect() async throws {
        do {
            try await runtime.start()
        } catch let error as AxolotyError {
            throw InspectorError.connectionUnavailable(reason: error.userFriendlyMessage)
        } catch {
            throw InspectorError.connectionUnavailable(reason: String(describing: error))
        }
    }

    public func transportState() async -> InspectorTransportState {
        switch await runtime.state() {
        case .running, .starting, .reconnecting: return .online
        case .initialized, .stopping, .stopped, .failed: return .offline
        }
    }

    public func advertiseEvents() async -> AsyncStream<InspectorAdvertiseEvent> {
        mapAdvertise(advertiseStream)
    }

    public func deadvertiseEvents() async -> AsyncStream<InspectorDeadvertiseEvent> {
        mapDeadvertise(deadvertiseStream)
    }

    public func discover(_ request: InspectorDiscoverRequest) async -> AsyncStream<InspectorResponseEvent> {
        let (stream, continuation) = AsyncStream<InspectorResponseEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        guard !discoveryInFlight else {
            // Inspector catalogue consumers are intentionally single-flight:
            // the runtime event stream is single-consumer, so admitting a
            // second request would allow the two requests to steal each
            // other's correlated responses. The bounded empty stream is a
            // deterministic rejection that preserves the existing API.
            continuation.finish()
            return stream
        }
        discoveryInFlight = true
        let correlation = Self.newCorrelation()
        discoveryCorrelation = correlation
        let runtime = self.runtime
        let resolveStream = self.resolveStream
        let responseTimeout = request.responseTimeout
        let protocolTimeoutMS = responseTimeout.map {
            UInt32(max(1, min(Int64(UInt32.max), $0.millisecondsValue)))
        }
        let task = Task { @MainActor in
            defer {
                self.discoveryInFlight = false
                self.discoveryTask = nil
                self.discoveryCorrelation = nil
            }
            let receipt = await runtime.request(
                .discover(
                    correlationID: correlation,
                    payload: request.payload,
                    timeoutMS: protocolTimeoutMS
                )
            )
            guard case .accepted = receipt else {
                continuation.finish()
                return
            }
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await event in resolveStream {
                        guard event.context.correlationID == correlation else { continue }
                        continuation.yield(Self.response(from: event))
                    }
                    return false
                }
                if let responseTimeout {
                    group.addTask {
                        try? await Task.sleep(for: responseTimeout)
                        return true
                    }
                }
                _ = await group.next()
                group.cancelAll()
                _ = await runtime.cancel(correlationID: correlation)
            }
            continuation.finish()
        }
        discoveryTask = task
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.cancelDiscovery()
            }
        }
        return stream
    }

    public func stop() {
        cancelDiscovery()
        Task { await runtime.stop() }
    }

    private func cancelDiscovery() {
        discoveryTask?.cancel()
        guard let correlation = discoveryCorrelation else { return }
        let runtime = self.runtime
        Task { _ = await runtime.cancel(correlationID: correlation) }
    }

    private func mapAdvertise(_ source: RuntimeEventStream) -> AsyncStream<InspectorAdvertiseEvent> {
        let (stream, continuation) = AsyncStream<InspectorAdvertiseEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        Task { @MainActor in
            for await event in source {
                if let value = Self.advertise(from: event) { continuation.yield(value) }
            }
            continuation.finish()
        }
        return stream
    }

    private func mapDeadvertise(_ source: RuntimeEventStream) -> AsyncStream<InspectorDeadvertiseEvent> {
        let (stream, continuation) = AsyncStream<InspectorDeadvertiseEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        Task { @MainActor in
            for await event in source {
                if let value = Self.deadvertise(from: event) { continuation.yield(value) }
            }
            continuation.finish()
        }
        return stream
    }

    private static func advertise(from event: RuntimeEventValue) -> InspectorAdvertiseEvent? {
        guard let root = jsonObject(event.value),
              let object = objectPayload(root["object"] as? [String: Any]) else { return nil }
        return InspectorAdvertiseEvent(
            sourceId: uuidString(event.context.sourceID),
            eventTypeFilter: nil,
            object: object,
            privateData: jsonString(root["privateData"])
        )
    }

    private static func deadvertise(from event: RuntimeEventValue) -> InspectorDeadvertiseEvent? {
        guard let values = try? JSONSerialization.jsonObject(with: Data(event.value)) as? [String] else { return nil }
        return InspectorDeadvertiseEvent(sourceId: uuidString(event.context.sourceID), objectIds: values)
    }

    nonisolated private static func response(from event: RuntimeEventValue) -> InspectorResponseEvent {
        InspectorResponseEvent(
            eventType: eventFamilyName(event.family),
            sourceId: uuidString(event.context.sourceID),
            correlationId: event.context.correlationID.map(uuidString),
            payload: String(decoding: event.value, as: UTF8.self)
        )
    }

    private static func objectPayload(_ value: [String: Any]?) -> InspectorObjectPayload? {
        guard let value,
              let objectId = value["objectId"] as? String,
              let objectType = value["objectType"] as? String,
              let core = value["coreType"] as? String else { return nil }
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return InspectorObjectPayload(
            objectId: objectId,
            coreType: InspectorCoreType(rawValue: core),
            objectType: objectType,
            name: value["name"] as? String ?? "",
            payload: data.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    private static func jsonObject(_ bytes: [UInt8]) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func eventFamilyName(_ family: RuntimeEventFamily) -> String {
        switch family {
        case .advertise: return "advertise"
        case .deadvertise: return "deadvertise"
        case .channel: return "channel"
        case .associate: return "associate"
        case .ioValue: return "ioValue"
        case .discover: return "discover"
        case .resolve: return "resolve"
        case .query: return "query"
        case .retrieve: return "retrieve"
        case .update: return "update"
        case .complete: return "complete"
        case .call: return "call"
        case .returnEvent: return "return"
        }
    }

    private static func newCorrelation() -> UUID16 {
        let uuid = UUID()
        return withUnsafeBytes(of: uuid.uuid) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return UUID16(bytes: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
        }
    }

    nonisolated private static func uuidString(_ value: UUID16) -> String {
        let b = value.bytes
        let bytes = [b.0,b.1,b.2,b.3,b.4,b.5,b.6,b.7,b.8,b.9,b.10,b.11,b.12,b.13,b.14,b.15]
        let hex = bytes.map { String(format: "%02x", $0) }
        return "\(hex[0])\(hex[1])\(hex[2])\(hex[3])\(hex[4])\(hex[5])\(hex[6])\(hex[7])-\(hex[8])\(hex[9])-\(hex[10])\(hex[11])-\(hex[12])\(hex[13])-\(hex[14])\(hex[15])\(hex[16])\(hex[17])\(hex[18])\(hex[19])\(hex[20])\(hex[21])\(hex[22])\(hex[23])\(hex[24])\(hex[25])\(hex[26])\(hex[27])\(hex[28])\(hex[29])\(hex[30])\(hex[31])"
    }
}

private extension Duration {
    var millisecondsValue: Int64 {
        let components = self.components
        return components.seconds * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}
