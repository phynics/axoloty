// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A loopback-only NIO HTTP server that fronts the MCP SDK's
/// ``StatefulHTTPServerTransport`` for the Streamable HTTP transport.
///
/// The server accepts HTTP connections, converts NIO HTTP request parts into
/// the SDK's framework-agnostic ``HTTPRequest`` values, routes them to the
/// matching session's transport, and writes the returned ``HTTPResponse``
/// values back over the connection. A new ``Server`` (and transport) is created
/// per session via ``serverFactory``; sessions are addressed by the
/// `MCP-Session-Id` header.
///
/// Only loopback hosts (`127.0.0.1`, `localhost`, `::1`) are accepted to keep
/// the inspector reachable solely from the local machine. DNS-rebinding
/// protection is provided by ``MCP/OriginValidator`` scoped to ``localhost(port:)``.
public actor MCPHTTPServer {
    /// Creates a new ``MCP/Server`` for an incoming session and starts it on
    /// the supplied transport.
    ///
    /// The factory owns ``Server/start(transport:)`` so it can register
    /// per-session handlers before the transport begins processing requests.
    public typealias ServerFactory = @Sendable (
        String,
        StatefulHTTPServerTransport
    ) async throws -> Server

    private let host: String
    private let port: UInt16
    private let endpoint: String
    private let serverFactory: ServerFactory
    private let validationPipeline: (any HTTPRequestValidationPipeline)?
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    /// Creates a new MCP HTTP server.
    ///
    /// - Parameters:
    ///   - host: Loopback bind address. Must be `127.0.0.1`, `localhost`, or
    ///     `::1`; any other value is rejected when ``start()`` runs.
    ///   - port: TCP port to bind.
    ///   - endpoint: MCP endpoint path (defaults to `/mcp`).
    ///   - validationPipeline: Custom validation pipeline forwarded to each
    ///     transport. If `nil`, a default pipeline scoped to
    ///     ``MCP/OriginValidator``.`localhost(port:)` is used.
    ///   - serverFactory: Factory invoked once per session to create and start
    ///     a ``MCP/Server`` on the freshly minted transport.
    public init(
        host: String,
        port: UInt16,
        endpoint: String = "/mcp",
        validationPipeline: (any HTTPRequestValidationPipeline)? = nil,
        serverFactory: @escaping ServerFactory
    ) {
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline
    }

    /// Starts the HTTP server and blocks until the server channel closes.
    ///
    /// - Throws: ``AxolotyError`` if `host` is not a loopback address, or a
    ///   NIO error if the channel cannot be bound.
    public func start() async throws {
        guard Self.isLoopback(host) else {
            throw AxolotyError.invalidConfiguration(
                option: "host",
                reason: "MCP HTTP server only accepts loopback hosts (127.0.0.1, localhost, ::1); got '\(host)'"
            )
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: host, port: Int(port)).get()
        self.channel = channel

        _Concurrency.Task { await sessionCleanupLoop() }

        try await channel.closeFuture.get()
    }

    /// Stops the HTTP server, closing all active sessions and the channel.
    public func stop() async {
        await closeAllSessions()
        try? await channel?.close()
        channel = nil
    }

    // MARK: - Request Routing

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Routes an incoming HTTP request to the appropriate session transport.
    fileprivate func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }

            return response
        }

        if request.method.uppercased() == "POST",
            let body = request.body,
            Self.isInitializeRequest(body)
        {
            return await createSessionAndHandle(request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
        )
    }

    /// Classifies a raw JSON-RPC body as an `initialize` request.
    ///
    /// Mirrors the SDK's `JSONRPCMessageKind.isInitializeRequest`: a request
    /// is an initialization request when it carries a `method` of
    /// `"initialize"` together with a string or integer `id`.
    private static func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = json["method"] as? String,
            method == "initialize"
        else {
            return false
        }
        if json["id"] is String { return true }
        if json["id"] is Int { return true }
        return false
    }

    // MARK: - Session Management

    private struct FixedSessionIDGenerator: SessionIDGenerator {
        let sessionID: String
        func generateSessionID() -> String { sessionID }
    }

    private func createSessionAndHandle(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let pipeline = validationPipeline ?? StandardValidationPipeline(validators: [
            OriginValidator.localhost(port: Int(port)),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(sessionID: sessionID),
            validationPipeline: pipeline
        )

        do {
            let server = try await serverFactory(sessionID, transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
    }

    private func closeAllSessions() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func sessionCleanupLoop() async {
        while true {
            try? await _Concurrency.Task.sleep(for: .seconds(60))

            let now = Date()
            let expired = sessions.filter { _, context in
                now.timeIntervalSince(context.lastAccessedAt) > 3600
            }

            for (sessionID, _) in expired {
                await closeSession(sessionID)
            }
        }
    }
}

// MARK: - NIO HTTP Handler

/// Thin NIO adapter that converts between NIO HTTP types and the
/// framework-agnostic `HTTPRequest`/`HTTPResponse` types, delegating all
/// logic to ``MCPHTTPServer``.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: MCPHTTPServer

    private struct RequestState {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var requestState: RequestState?

    init(app: MCPHTTPServer) {
        self.app = app
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestState = RequestState(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            requestState?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let state = requestState else { return }
            requestState = nil

            nonisolated(unsafe) let ctx = context
            _Concurrency.Task { @MainActor in
                await self.handleRequest(state: state, context: ctx)
            }
        }
    }

    // MARK: - Request Processing

    private func handleRequest(state: RequestState, context: ChannelHandlerContext) async {
        let head = state.head
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri
        let endpoint = await app.endpointPath()

        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        let httpRequest = makeHTTPRequest(from: state)
        let response = await app.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    // MARK: - NIO ↔ HTTPRequest/HTTPResponse Conversion

    private func makeHTTPRequest(from state: RequestState) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in state.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if state.bodyBuffer.readableBytes > 0,
            let bytes = state.bodyBuffer.getBytes(at: 0, length: state.bodyBuffer.readableBytes)
        {
            body = Data(bytes)
        } else {
            body = nil
        }

        let path = String(state.head.uri.split(separator: "?").first ?? Substring(state.head.uri))

        return HTTPRequest(
            method: state.head.method.rawValue,
            headers: headers,
            body: body,
            path: path
        )
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        let statusCode = response.statusCode
        let headers = response.headers

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(
                            self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — close connection
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    head.headers.add(name: name, value: value)
                }

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

extension MCPHTTPServer {
    /// Exposes the configured endpoint path to the NIO handler.
    fileprivate func endpointPath() -> String { endpoint }
}
