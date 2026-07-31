// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import Foundation
import MCP

/// The Axoloty MCP server.
///
/// Connects to an MQTT broker through Axoloty, maintains a passive object
/// catalogue, and exposes read-only inspection capabilities through MCP
/// tools and resources.
@MainActor
public final class AxolotyMCPServer {
    private let server: Server
    private let catalogueService: InspectorCatalogueService
    private let session: InspectorSession

    /// Creates the MCP server.
    ///
    /// - Parameters:
    ///   - host: MQTT broker host.
    ///   - port: MQTT broker port.
    ///   - namespace: Coaty namespace.
    /// - Throws: ``InspectorError`` if the underlying inspector session
    ///   cannot be configured.
    public init(host: String, port: UInt16, namespace: String) throws {
        let connectionConfig = InspectorConnectionConfiguration(
            host: host,
            port: port,
            namespace: namespace
        )
        let session = try AxolotyInspectorSession(configuration: connectionConfig)
        self.session = session
        self.catalogueService = InspectorCatalogueService(session: session, namespace: namespace)
        self.server = Server(
            name: "axoloty-mcp",
            version: "0.2.0",
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
    }

    /// Starts the MCP server with stdio transport.
    ///
    /// stdin and stdout are reserved for MCP protocol messages.
    /// All diagnostics go to stderr.
    ///
    /// - Throws: ``InspectorError`` if the broker connection fails, or an
    ///   `MCPError` if the transport cannot be established.
    public func startStdio() async throws {
        try await catalogueService.start()
        await registerHandlers()
        let transport = StdioTransport()
        try await server.start(transport: transport)
    }

    /// Stops the MCP server and disconnects from MQTT.
    public func stop() async {
        await server.stop()
        catalogueService.stop()
    }

    // MARK: - Handler registration

    private func registerHandlers() async {
        let service = catalogueService

        // List tools
        await server.withMethodHandler(ListTools.self) { _ in
            return .init(tools: [
                Tool(
                    name: "axoloty_list_objects",
                    description: "List objects from the passive catalogue. The catalogue is incomplete — it only contains objects advertised since the observer connected.",
                    inputSchema: .object([
                        "properties": .object([
                            "coreType": .string("Filter by core type (e.g. Identity, Task)"),
                            "objectType": .string("Filter by full object type"),
                            "objectId": .string("Filter by object UUID"),
                            "sourceId": .string("Filter by source (advertiser) UUID"),
                        ])
                    ])
                ),
                Tool(
                    name: "axoloty_get_object",
                    description: "Get a specific object by ID from the passive catalogue.",
                    inputSchema: .object([
                        "properties": .object([
                            "objectId": .string("The object UUID to look up")
                        ]),
                        "required": .array([.string("objectId")])
                    ])
                ),
                Tool(
                    name: "axoloty_discover_objects",
                    description: "Actively discover objects by publishing one Discover event and collecting Resolve responses.",
                    inputSchema: .object([
                        "properties": .object([
                            "coreType": .string("Filter by core type"),
                            "objectType": .string("Filter by object type"),
                            "objectId": .string("Filter by object UUID"),
                            "timeoutMilliseconds": .string("Timeout in milliseconds (default: 5000, max: 30000)")
                        ])
                    ])
                ),
                Tool(
                    name: "axoloty_server_status",
                    description: "Get the current server status including MQTT connection state and catalogue metrics.",
                    inputSchema: .object([:])
                ),
            ])
        }

        // Call tool
        await server.withMethodHandler(CallTool.self) { [self] params in
            switch params.name {
            case "axoloty_list_objects":
                return await self.handleListObjects(params.arguments, service: service)
            case "axoloty_get_object":
                return await self.handleGetObject(params.arguments, service: service)
            case "axoloty_discover_objects":
                return await self.handleDiscoverObjects(params.arguments, service: service)
            case "axoloty_server_status":
                return await self.handleServerStatus(service: service)
            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
        }

        // List resources
        await server.withMethodHandler(ListResources.self) { _ in
            return .init(resources: [
                Resource(name: "Status", uri: "axoloty://status", description: "Server status"),
                Resource(name: "Catalogue", uri: "axoloty://catalogue", description: "Passive object catalogue"),
            ], nextCursor: nil)
        }

        // Read resource
        await server.withMethodHandler(ReadResource.self) { [self] params in
            switch params.uri {
            case "axoloty://status":
                let status = await self.collectStatus(service: service)
                let json = try Self.encodeStatus(status)
                return .init(contents: [.text(json, uri: params.uri, mimeType: "application/json")])
            case "axoloty://catalogue":
                let snapshot = await service.store.snapshot(filter: ObjectCatalogueFilter())
                let json = try Self.encodeSnapshot(snapshot)
                return .init(contents: [.text(json, uri: params.uri, mimeType: "application/json")])
            default:
                throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
            }
        }
    }

    // MARK: - Tool handlers

    private func handleListObjects(_ args: [String: Value]?, service: InspectorCatalogueService) async -> CallTool.Result {
        let filter = Self.parseFilter(args)
        let snapshot = await service.store.snapshot(filter: filter)
        let json = (try? Self.encodeSnapshot(snapshot)) ?? "{}"
        return .init(content: [.text(json)], isError: false)
    }

    private func handleGetObject(_ args: [String: Value]?, service: InspectorCatalogueService) async -> CallTool.Result {
        guard let objectId = args?["objectId"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: objectId")], isError: true)
        }
        if let object = await service.store.object(id: objectId) {
            let json = (try? Self.encodeObject(object)) ?? "{}"
            return .init(content: [.text(json)], isError: false)
        }
        return .init(content: [.text("Object not found: \(objectId)")], isError: false)
    }

    private func handleDiscoverObjects(_ args: [String: Value]?, service: InspectorCatalogueService) async -> CallTool.Result {
        let coreType = args?["coreType"]?.stringValue
        let objectType = args?["objectType"]?.stringValue
        let objectId = args?["objectId"]?.stringValue
        let timeoutMs = args?["timeoutMilliseconds"]?.intValue ?? 5000
        let clampedTimeout = min(max(timeoutMs, 1000), 30000)

        let request = InspectorDiscoveryRequest(
            coreType: coreType,
            objectType: objectType,
            objectId: objectId,
            timeoutMilliseconds: clampedTimeout
        )

        guard request.hasSelector else {
            return .init(content: [.text("At least one selector (coreType, objectType, or objectId) is required")], isError: true)
        }

        let discoverEvent = Self.makeDiscoverEvent(from: request)
        let responseStream = await session.discover(discoverEvent)
        let timeout = Duration.milliseconds(clampedTimeout)

        var discoveredObjects: [String: InspectorObject] = [:]
        var timedOut = false

        let (eventStream, continuation) = AsyncStream.makeStream(of: DiscoverLoopEvent.self)

        let responseTask = _Concurrency.Task {
            var it = responseStream.makeAsyncIterator()
            while let response = await it.next() {
                continuation.yield(.response(response))
            }
            continuation.yield(.responsesExhausted)
        }

        let timerTask = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(for: timeout)
            continuation.yield(.timeoutExpired)
        }

        var done = false
        var eventIterator = eventStream.makeAsyncIterator()
        while !done, let event = await eventIterator.next() {
            switch event {
            case .response(let response):
                if let payload = response.decodePayload(ResolvePayload.self) {
                    let object = payload.object
                    if discoveredObjects[object.objectId] == nil {
                        discoveredObjects[object.objectId] = InspectorObject(
                            objectId: object.objectId,
                            coreType: object.coreType.rawValue,
                            objectType: object.objectType,
                            name: object.name.isEmpty ? nil : object.name,
                            sourceId: response.sourceId
                        )
                    }
                }
            case .responsesExhausted:
                timedOut = true
                done = true
            case .timeoutExpired:
                timedOut = true
                done = true
            }
        }

        continuation.finish()
        responseTask.cancel()
        timerTask.cancel()
        _ = await responseTask.value
        _ = await timerTask.value

        let objects = Array(discoveredObjects.values).sorted { $0.objectId < $1.objectId }
        let result = InspectorDiscoveryResult(timedOut: timedOut, objects: objects)
        let json = (try? Self.encodeDiscoveryResult(result)) ?? "{}"
        return .init(content: [.text(json)], isError: false)
    }

    private func handleServerStatus(service: InspectorCatalogueService) async -> CallTool.Result {
        let status = await collectStatus(service: service)
        let json = (try? Self.encodeStatus(status)) ?? "{}"
        return .init(content: [.text(json)], isError: false)
    }

    // MARK: - Helpers

    private func collectStatus(service: InspectorCatalogueService) async -> ServerStatus {
        let count = await service.store.count
        let snapshot = await service.store.snapshot(filter: ObjectCatalogueFilter())
        return ServerStatus(
            mqttConnected: true,
            namespace: snapshot.namespace,
            catalogueObservedSince: snapshot.observedSince,
            catalogueObjectCount: count
        )
    }

    private struct ServerStatus: Codable, Sendable {
        let mqttConnected: Bool
        let namespace: String
        let catalogueObservedSince: String
        let catalogueObjectCount: Int
    }

    private struct ResolvePayload: Decodable {
        let object: CoatyObjectSnapshot
    }

    private static func parseFilter(_ args: [String: Value]?) -> ObjectCatalogueFilter {
        ObjectCatalogueFilter(
            coreType: args?["coreType"]?.stringValue,
            objectType: args?["objectType"]?.stringValue,
            objectId: args?["objectId"]?.stringValue,
            sourceId: args?["sourceId"]?.stringValue
        )
    }

    private static func makeDiscoverEvent(from request: InspectorDiscoveryRequest) -> DiscoverEvent {
        if let objectIdString = request.objectId,
           let uuid = CoatyUUID(uuidString: objectIdString) {
            return DiscoverEvent.with(objectId: uuid)
        }
        if let objectTypes = request.objectType.map({ [$0] }) {
            return DiscoverEvent.with(objectTypes: objectTypes)
        }
        if let coreTypeString = request.coreType,
           let coreType = CoreType(rawValue: coreTypeString) {
            return DiscoverEvent.with(coreTypes: [coreType])
        }
        return DiscoverEvent.with(coreTypes: [])
    }

    nonisolated private static func encodeSnapshot(_ snapshot: InspectorCatalogueSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func encodeObject(_ object: InspectorObject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(object)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func encodeDiscoveryResult(_ result: InspectorDiscoveryResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func encodeStatus(_ status: ServerStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(status)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Tool content convenience

private extension Tool.Content {
    /// Plain text content with no annotations or metadata.
    ///
    /// Bridges to the non-deprecated `text(text:annotations:_meta:)` case,
    /// avoiding the deprecated `text(_:metadata:)` factory.
    static func text(_ text: String) -> Self {
        .text(text: text, annotations: nil, _meta: nil)
    }
}

// MARK: - Discovery loop events

private enum DiscoverLoopEvent: Sendable {
    case response(ResponseEventSnapshot)
    case responsesExhausted
    case timeoutExpired
}
