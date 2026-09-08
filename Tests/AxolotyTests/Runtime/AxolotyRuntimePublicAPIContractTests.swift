// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyTestSupport
import AxolotyWire

extension AxolotyRuntimeTests {
    @Test("run stops the runtime when its task is canceled")
    func runStopsOnCancellation() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        let running = Task {
            try await runtime.run()
        }
        try await waitUntil("runtime to start before cancellation") {
            await runtime.state() == .running
        }

        running.cancel()
        do {
            try await running.value
        } catch {
            Issue.record("run propagated cancellation after performing its shutdown: \(error)")
        }
        #expect(await runtime.state() == .stopped)
    }

    @Test("run terminates after an external stop")
    func runTerminatesAfterStop() async throws {
        let runtime = AxolotyRuntime(definition: try makeDefinition(), transport: TestTransport())
        let running = Task {
            try await runtime.run()
        }
        try await waitUntil("runtime to start before stopping") {
            await runtime.state() == .running
        }

        await runtime.stop()
        do {
            try await running.value
        } catch {
            Issue.record("run propagated an error after external stop: \(error)")
        }
        #expect(await runtime.state() == .stopped)
    }

    @Test("typed IO publishes and delivers values through the injected transport")
    func typedIoUsesInjectedTransport() async throws {
        let sourceID = "00000000-0000-4000-8000-000000000801"
        let actorID = "00000000-0000-4000-8000-000000000802"
        var builder = try RuntimeBuilder(
            sourceID: .zero,
            namespace: "io-api-contract"
        )
        let source = try builder.ioSource(
            metadata: try contractSourceMetadata(sourceID),
            as: Bool.self
        )
        let delivered = IoActorDeliveryRecorder()
        _ = try builder.ioActor(
            metadata: try contractActorMetadata(actorID),
            as: Bool.self
        ) { value, context in
            await delivered.record(value, context: context)
        }
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        await transport.deliver(.profile(
            route: "coaty/3/io-api-contract/ASC/\(sourceID)",
            payload: Array("{\"ioSourceId\":\"\(sourceID)\",\"ioActorId\":\"\(actorID)\",\"associatingRoute\":\"coaty/io-api-contract\"}".utf8),
            nowMS: 1
        ))
        try await waitUntil("typed IO association to reach the runtime") {
            try await runtime.io.state(of: source).hasAssociations
        }

        #expect(try await runtime.io.publish(true, from: source, nowMS: 2) == .published)
        try await waitUntil("typed IO publication to reach the injected transport") {
            guard let publication = await transport.lastSent() else { return false }
            return routeEventType(publication.route) == ProtocolCapability.ioValue.wireEventType.wireCode.description
                && publication.payload == Array("true".utf8)
        }
        let publication = try #require(await transport.lastSent())
        #expect(routeEventType(publication.route) == ProtocolCapability.ioValue.wireEventType.wireCode.description)
        #expect(publication.payload == Array("true".utf8))

        await transport.deliver(.profile(
            route: "coaty/3/io-api-contract/IOV/\(sourceID)",
            payload: Array("true".utf8),
            nowMS: 3
        ))
        try await waitUntil("typed IO actor delivery") {
            await delivered.values.count == 1
        }
        #expect(await delivered.values == [true])
        #expect(await delivered.contexts.first?.routeKind == .coaty)
        await runtime.stop()
    }

    @Test("RuntimeBuilder handlers receive normalized invocations")
    func builderHandlerIsInvoked() async throws {
        let correlationText = "00000000-0000-4000-8000-000000000811"
        _ = try #require(UUID16(parsing: correlationText))
        let invocation = InvocationRecorder()
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "handler-api-contract")
        _ = try builder.respond(to: .call(operation: "device.read")) { value in
            await invocation.record(value)
            return .noResponse
        }
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()

        await transport.deliver(.profile(
            route: "coaty/3/handler-api-contract/CLL:device.read/00000000-0000-4000-8000-000000000812/\(correlationText)",
            payload: Array("{\"parameters\":{\"operand\":7}}".utf8),
            nowMS: 4
        ))
        try await waitUntil("registered handler invocation") {
            await invocation.operations.count == 1
        }
        #expect(await invocation.operations == ["device.read"])
        #expect(await invocation.payloads == [Array("{\"parameters\":{\"operand\":7}}".utf8)])
        await runtime.stop()
    }

    @Test("handler failures produce bounded diagnostics")
    func handlerFailureProducesDiagnostic() async throws {
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "handler-error-contract")
        _ = try builder.respond(to: .call(operation: "device.fail")) { _ in
            throw ContractHandlerFailure()
        }
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()
        let diagnostics = await runtime.diagnostics()
        var iterator = diagnostics.makeAsyncIterator()

        let correlationText = "00000000-0000-4000-8000-000000000821"
        _ = try #require(UUID16(parsing: correlationText))
        await transport.deliver(.profile(
            route: "coaty/3/handler-error-contract/CLL:device.fail/00000000-0000-4000-8000-000000000822/\(correlationText)",
            payload: Array("{}".utf8),
            nowMS: 5
        ))
        let diagnostic = try await nextValue(&iterator)
        #expect(diagnostic.kind == .handlerFailed)
        #expect(diagnostic.detail.contains("expected handler failure"))
        #expect((await runtime.diagnosticsSnapshot()).handlerSaturation == 0)
        await runtime.stop()
    }

    @Test("handler responses publish through the injected transport")
    func handlerResponseUsesInjectedTransport() async throws {
        let correlationText = "00000000-0000-4000-8000-000000000831"
        _ = try #require(UUID16(parsing: correlationText))
        let responsePayload = Array("{\"result\":{\"answer\":42}}".utf8)
        var builder = try RuntimeBuilder(sourceID: .zero, namespace: "response-api-contract")
        _ = try builder.respond(to: .call(operation: "device.read")) { _ in
            .response(responsePayload)
        }
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)
        try await runtime.start()
        await transport.deliver(.profile(
            route: "coaty/3/response-api-contract/CLL:device.read/00000000-0000-4000-8000-000000000832/\(correlationText)",
            payload: Array("{}".utf8),
            nowMS: 6
        ))
        try await waitUntil("handler response to reach the injected transport") {
            await transport.sentCount() == 1
        }
        let publication = try #require(await transport.lastSent())
        #expect(routeEventType(publication.route) == ProtocolCapability.returnEvent.wireEventType.wireCode.description)
        #expect(publication.route.hasSuffix("/\(correlationText)"))
        #expect(publication.payload == responsePayload)
        await runtime.stop()
    }
}

private actor IoActorDeliveryRecorder {
    private(set) var values: [Bool] = []
    private(set) var contexts: [IoDeliveryContext] = []

    func record(_ value: Bool, context: IoDeliveryContext) {
        values.append(value)
        contexts.append(context)
    }
}

private actor InvocationRecorder {
    private(set) var operations: [String?] = []
    private(set) var payloads: [[UInt8]] = []

    func record(_ invocation: RuntimeInvocation) {
        operations.append(invocation.operation)
        if case let .deliver(delivery) = invocation.action {
            payloads.append(delivery.payload)
        }
    }
}

private struct ContractHandlerFailure: Error, CustomStringConvertible {
    var description: String { "expected handler failure" }
}

private func contractSourceMetadata(_ id: String) throws -> Object<IoSourceMetadata> {
    let json: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000801\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
    _ = id
    return try Object<IoSourceMetadata>(decoding: ByteSlice(
        bytes: json.utf8Start,
        length: json.utf8CodeUnitCount
    ))
}

private func contractActorMetadata(_ id: String) throws -> Object<IoActorMetadata> {
    let json: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000802\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
    _ = id
    return try Object<IoActorMetadata>(decoding: ByteSlice(
        bytes: json.utf8Start,
        length: json.utf8CodeUnitCount
    ))
}
