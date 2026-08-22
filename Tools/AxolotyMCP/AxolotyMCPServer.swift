// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyInspectorCore
import AxolotyInspectorRuntime
import ErrorKit
import Foundation
import Logging
import MCP

private func makeMCPPropertySchema(type: String, description: String) -> Value {
    .object([
        "type": .string(type),
        "description": .string(description),
    ])
}

/// The Axoloty MCP server.
///
/// Connects to an MQTT broker through Axoloty, maintains a passive object
/// catalogue, and exposes read-only inspection capabilities through MCP
/// tools and resources.
@MainActor
public final class AxolotyMCPServer {
    private static let logger = Logger(label: "axoloty.mcp")
    private let server: Server
    private let catalogueService: InspectorCatalogueService
    private let session: InspectorSession
    private let responseEncoder: ResponseEncoder
    private let encodingFailureLogger: EncodingFailureLogger
    private var httpServer: MCPHTTPServer?
    private var catalogueStartTask: Task<Void, Never>? = nil

    typealias SnapshotEncoder = (InspectorCatalogueSnapshot) throws -> String
    typealias ObjectEncoder = (InspectorObject) throws -> String
    typealias DiscoveryEncoder = (InspectorDiscoveryResult) throws -> String
    typealias StatusEncoder = (ServerStatus) throws -> String
    typealias EncodingFailureLogger = @MainActor @Sendable (String, Logging.Logger.Metadata) -> Void

    struct ResponseEncoder {
        let snapshot: SnapshotEncoder
        let object: ObjectEncoder
        let discovery: DiscoveryEncoder
        let status: StatusEncoder

        init(
            snapshot: @escaping SnapshotEncoder = AxolotyMCPServer.encodeSnapshot,
            object: @escaping ObjectEncoder = AxolotyMCPServer.encodeObject,
            discovery: @escaping DiscoveryEncoder = AxolotyMCPServer.encodeDiscoveryResult,
            status: @escaping StatusEncoder = AxolotyMCPServer.encodeStatus
        ) {
            self.snapshot = snapshot
            self.object = object
            self.discovery = discovery
            self.status = status
        }
    }

    nonisolated static let discoverObjectsTool = Tool(
        name: "axoloty_discover_objects",
        description: "Actively discover objects by publishing one Discover event and collecting Resolve responses.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "coreType": makeMCPPropertySchema(type: "string", description: "Filter by core type"),
                "objectType": makeMCPPropertySchema(type: "string", description: "Filter by object type"),
                "objectId": makeMCPPropertySchema(type: "string", description: "Filter by object UUID"),
                "timeoutMilliseconds": makeMCPPropertySchema(
                    type: "integer",
                    description: "Timeout in milliseconds (default: 5000, max: 30000)"
                ),
            ])
        ])
    )

    nonisolated static let objectInputSchemaTools: [Tool] = [
        Tool(
            name: "axoloty_list_objects",
            description: "List objects from the passive catalogue. The catalogue is incomplete — it only contains objects advertised since the observer connected.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "coreType": makeMCPPropertySchema(type: "string", description: "Filter by core type (e.g. Identity, Task)"),
                    "objectType": makeMCPPropertySchema(type: "string", description: "Filter by full object type"),
                    "objectId": makeMCPPropertySchema(type: "string", description: "Filter by object UUID"),
                    "sourceId": makeMCPPropertySchema(type: "string", description: "Filter by source (advertiser) UUID"),
                ])
            ])
        ),
        Tool(
            name: "axoloty_get_object",
            description: "Get a specific object by ID from the passive catalogue.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "objectId": makeMCPPropertySchema(type: "string", description: "The object UUID to look up")
                ]),
                "required": .array([.string("objectId")])
            ])
        ),
        discoverObjectsTool,
        Tool(
            name: "axoloty_server_status",
            description: "Get the current server status including MQTT connection state and catalogue metrics.",
            inputSchema: .object([
                "type": .string("object"),
            ])
        ),
    ]

    /// Creates the MCP server.
    ///
    /// - Parameters:
    ///   - host: MQTT broker host.
    ///   - port: MQTT broker port.
    ///   - namespace: Coaty namespace.
    ///   - connectTimeout: Broker readiness timeout.
    /// - Throws: ``InspectorError`` if the underlying inspector session
    ///   cannot be configured.
    public init(
        host: String,
        port: UInt16,
        namespace: String,
        connectTimeout: Duration = .seconds(10)
    ) throws {
        let connectionConfig = Self.makeConnectionConfiguration(
            host: host,
            port: port,
            namespace: namespace,
            connectTimeout: connectTimeout
        )
        let session = try AxolotyInspectorSession(configuration: connectionConfig)
        self.session = session
        self.catalogueService = InspectorCatalogueService(session: session, namespace: namespace)
        self.responseEncoder = ResponseEncoder()
        self.encodingFailureLogger = Self.logEncodingFailure
        self.server = Server(
            name: "axoloty-mcp",
            version: InspectorArgumentParser.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )
    }

    nonisolated static func makeConnectionConfiguration(
        host: String,
        port: UInt16,
        namespace: String,
        connectTimeout: Duration
    ) -> InspectorConnectionConfiguration {
        InspectorConnectionConfiguration(
            host: host,
            port: port,
            namespace: namespace,
            connectTimeout: connectTimeout
        )
    }

    init(
        session: InspectorSession,
        namespace: String,
        responseEncoder: ResponseEncoder = ResponseEncoder(),
        encodingFailureLogger: @escaping EncodingFailureLogger = AxolotyMCPServer.logEncodingFailure
    ) {
        self.session = session
        self.catalogueService = InspectorCatalogueService(session: session, namespace: namespace)
        self.responseEncoder = responseEncoder
        self.encodingFailureLogger = encodingFailureLogger
        self.server = Server(
            name: "axoloty-mcp",
            version: InspectorArgumentParser.version,
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
        await registerHandlers(on: server)
        let transport = StdioTransport()
        try await server.start(transport: transport)
    }

    /// Starts the MCP server with Streamable HTTP transport.
    ///
    /// Binds a loopback-only HTTP server that fronts the MCP SDK's
    /// ``MCP/StatefulHTTPServerTransport``. A new ``MCP/Server`` is created
    /// per session, all sharing the same broker-backed catalogue so concurrent
    /// clients observe the same live objects.
    ///
    /// - Parameters:
    ///   - listenHost: Loopback bind address (`127.0.0.1`, `localhost`, `::1`).
    ///   - listenPort: TCP port to bind.
    ///   - path: MCP endpoint path (defaults to `/mcp`).
    /// - Throws: ``InspectorError`` if the broker connection fails,
    ///   ``AxolotyError`` if `listenHost` is not loopback, or an `MCPError` if
    ///   the HTTP server cannot start.
    public func startHTTP(listenHost: String, listenPort: UInt16, path: String = "/mcp") async throws {
        let httpServer = MCPHTTPServer(
            host: listenHost,
            port: listenPort,
            endpoint: path,
            serverFactory: { _, transport in
                let server = Server(
                    name: "axoloty-mcp",
                    version: InspectorArgumentParser.version,
                    capabilities: .init(
                        resources: .init(subscribe: false, listChanged: false),
                        tools: .init(listChanged: false)
                    )
                )
                await self.registerHandlers(on: server)
                try await server.start(transport: transport)
                return server
            }
        )
        self.httpServer = httpServer
        let startTask = Task { @MainActor [catalogueService] () -> Void in
            _ = try? await catalogueService.start()
        }
        self.catalogueStartTask = startTask
        do {
            try await httpServer.start()
        } catch {
            startTask.cancel()
            self.catalogueStartTask = nil
            self.httpServer = nil
            await httpServer.stop()
            throw error
        }
    }

    /// Stops the MCP server and disconnects from MQTT.
    public func stop() async {
        let httpServer = httpServer
        self.httpServer = nil
        catalogueStartTask?.cancel()
        catalogueStartTask = nil
        await httpServer?.stop()
        await server.stop()
        catalogueService.stop()
    }

    // MARK: - Handler registration

    func registerHandlers(on server: Server) async {
        let service = catalogueService

        // List tools
        await server.withMethodHandler(ListTools.self) { _ in
            return .init(tools: Self.objectInputSchemaTools)
        }

        // Call tool
        await server.withMethodHandler(CallTool.self) { [self] params in
            switch params.name {
            case "axoloty_list_objects":
                return await self.handleListObjects(params.arguments, service: service)
            case "axoloty_get_object":
                return await self.handleGetObject(params.arguments, service: service)
            case "axoloty_discover_objects":
                return await self.handleDiscoverObjects(params.arguments)
            case "axoloty_server_status":
                return await self.handleServerStatus()
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
                let status = await self.collectStatus()
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
        do {
            let json = try responseEncoder.snapshot(snapshot)
            return .init(content: [.text(json)], isError: false)
        } catch {
            return Self.encodingFailureResult(
                operation: "axoloty_list_objects",
                error: error,
                logger: encodingFailureLogger
            )
        }
    }

    private func handleGetObject(_ args: [String: Value]?, service: InspectorCatalogueService) async -> CallTool.Result {
        guard let objectId = args?["objectId"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: objectId")], isError: true)
        }
        if let object = await service.store.object(id: objectId) {
            do {
                let json = try responseEncoder.object(object)
                return .init(content: [.text(json)], isError: false)
            } catch {
                return Self.encodingFailureResult(
                    operation: "axoloty_get_object",
                    error: error,
                    logger: encodingFailureLogger
                )
            }
        }
        return .init(content: [.text("Object not found: \(objectId)")], isError: false)
    }

    private func handleDiscoverObjects(_ args: [String: Value]?) async -> CallTool.Result {
        await Self.handleDiscoverObjects(
            args,
            responseEncoder: responseEncoder,
            encodingFailureLogger: encodingFailureLogger,
            discover: { [session] event in
                await Self.discoveryResponseStream(session: session, event: event)
            }
        )
    }

    static func discoveryResponseStream(
        session: InspectorSession,
        event: InspectorDiscoverRequest
    ) async -> AsyncThrowingStream<InspectorResponseEvent, Error> {
        let responseStream = await session.discover(event)
        return AsyncThrowingStream { continuation in
            let responseTask = Task {
                for await response in responseStream {
                    guard !Task.isCancelled else { return }
                    continuation.yield(response)
                }
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
            let stateTask = Task {
                while !Task.isCancelled {
                    if await session.transportState() == .offline {
                        continuation.finish(throwing: AxolotyError.runtime(
                            code: .streamEnded,
                            reason: "Broker communication transitioned offline during discovery"
                        ))
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                responseTask.cancel()
                stateTask.cancel()
            }
        }
    }

    static func handleDiscoverObjects(
        _ args: [String: Value]?,
        responseEncoder: ResponseEncoder = ResponseEncoder(),
        encodingFailureLogger: EncodingFailureLogger = AxolotyMCPServer.logEncodingFailure,
        discover: (InspectorDiscoverRequest) async -> AsyncThrowingStream<InspectorResponseEvent, Error>
    ) async -> CallTool.Result {
        let request = Self.makeDiscoveryRequest(from: args)

        guard request.hasSelector else {
            return .init(content: [.text("At least one selector (coreType, objectType, or objectId) is required")], isError: true)
        }

        let discoverEvent: InspectorDiscoverRequest
        do {
            discoverEvent = try request.makeInspectorDiscoverRequest()
        } catch {
            return .init(content: [.text(error.userFriendlyMessage)], isError: true)
        }
        let responseStream = await discover(discoverEvent)
        let timeout = Duration.milliseconds(request.timeoutMilliseconds)

        var discoveredObjects: [String: InspectorObject] = [:]

        let (eventStream, continuation) = AsyncStream.makeStream(of: DiscoverLoopEvent.self)

        let responseTask = Task {
            var it = responseStream.makeAsyncIterator()
            do {
                while !Task.isCancelled, let response = try await it.next() {
                    continuation.yield(.response(response))
                }
                guard !Task.isCancelled else { return }
                continuation.yield(.responsesExhausted)
            } catch is CancellationError {
                // Cancellation is a cleanup path, not a response-stream error.
            } catch {
                guard !Task.isCancelled else { return }
                let wrapped = AxolotyError.caught(error)
                continuation.yield(.responseStreamFailed(
                    reason: ErrorKit.errorChainDescription(for: wrapped)
                ))
            }
        }

        let timerTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.timeoutExpired)
        }

        let terminalEvent: DiscoverLoopEvent? = await withTaskCancellationHandler {
            var eventIterator = eventStream.makeAsyncIterator()
            while let event = await eventIterator.next() {
                switch event {
                case .response(let response):
                    if let objects = InspectorResolveObjectDecoder.objects(from: response) {
                        for object in objects where discoveredObjects[object.objectId] == nil {
                            discoveredObjects[object.objectId] = object
                        }
                    }
                case .responsesExhausted, .timeoutExpired, .responseStreamFailed:
                    return event
                }
            }
            return nil
        } onCancel: {
            continuation.finish()
            responseTask.cancel()
            timerTask.cancel()
        }

        continuation.finish()
        responseTask.cancel()
        timerTask.cancel()
        _ = await responseTask.value
        _ = await timerTask.value

        if Task.isCancelled {
            return .init(content: [.text("Discovery cancelled")], isError: true)
        }

        guard let terminalEvent else {
            return .init(
                content: [.text("MCP response stream exhausted: abrupt transport close (coordination stream closed)")],
                isError: true
            )
        }

        switch terminalEvent {
        case .responsesExhausted:
            return .init(content: [.text("MCP response stream exhausted: clean EOF before deadline")], isError: true)
        case let .responseStreamFailed(reason):
            return .init(
                content: [.text("MCP response stream exhausted: abrupt transport close (\(reason))")],
                isError: true
            )
        case .response, .timeoutExpired:
            break
        }

        let objects = Array(discoveredObjects.values).sorted { $0.objectId < $1.objectId }
        let timedOut: Bool
        if case .timeoutExpired = terminalEvent {
            timedOut = true
        } else {
            timedOut = false
        }
        let result = InspectorDiscoveryResult(timedOut: timedOut, objects: objects)
        do {
            let json = try responseEncoder.discovery(result)
            return .init(content: [.text(json)], isError: false)
        } catch {
            return Self.encodingFailureResult(
                operation: "axoloty_discover_objects",
                error: error,
                logger: encodingFailureLogger
            )
        }
    }

    nonisolated static func makeDiscoveryRequest(from args: [String: Value]?) -> InspectorDiscoveryRequest {
        let timeoutMs = args?["timeoutMilliseconds"]?.intValue ?? 5000
        return InspectorDiscoveryRequest(
            coreType: args?["coreType"]?.stringValue,
            objectType: args?["objectType"]?.stringValue,
            objectId: args?["objectId"]?.stringValue,
            timeoutMilliseconds: min(max(timeoutMs, 1000), 30000)
        )
    }

    private func handleServerStatus() async -> CallTool.Result {
        let status = await collectStatus()
        do {
            let json = try responseEncoder.status(status)
            return .init(content: [.text(json)], isError: false)
        } catch {
            return Self.encodingFailureResult(
                operation: "axoloty_server_status",
                error: error,
                logger: encodingFailureLogger
            )
        }
    }

    // MARK: - Helpers

    func collectStatus() async -> ServerStatus {
        let count = await catalogueService.store.count
        let snapshot = await catalogueService.store.snapshot(filter: ObjectCatalogueFilter())
        let transportState = await catalogueService.transportState()
        return ServerStatus(
            mqttConnected: transportState == .online,
            namespace: snapshot.namespace,
            catalogueObservedSince: snapshot.observedSince,
            catalogueObjectCount: count
        )
    }

    struct ServerStatus: Codable, Sendable {
        let mqttConnected: Bool
        let namespace: String
        let catalogueObservedSince: String
        let catalogueObjectCount: Int
    }

    private static func parseFilter(_ args: [String: Value]?) -> ObjectCatalogueFilter {
        ObjectCatalogueFilter(
            coreType: args?["coreType"]?.stringValue,
            objectType: args?["objectType"]?.stringValue,
            objectId: args?["objectId"]?.stringValue,
            sourceId: args?["sourceId"]?.stringValue
        )
    }

    private static let encodingFailureMessage = "Unable to encode MCP response; please retry the request."

    private static func encodingFailureResult(
        operation: String,
        error: Error,
        logger: EncodingFailureLogger
    ) -> CallTool.Result {
        let wrapped = AxolotyError.caught(error)
        logger("Failed to encode MCP response", [
            "operation": .string(operation),
            "error": .string(ErrorKit.errorChainDescription(for: wrapped)),
        ])
        return .init(content: [.text(encodingFailureMessage)], isError: true)
    }

    private static func logEncodingFailure(
        _: String,
        _ metadata: Logging.Logger.Metadata
    ) {
        logger.error("Failed to encode MCP response", metadata: metadata)
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
    case response(InspectorResponseEvent)
    case responsesExhausted
    case timeoutExpired
    case responseStreamFailed(reason: String)
}
