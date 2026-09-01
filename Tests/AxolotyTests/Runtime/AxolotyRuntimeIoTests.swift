// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire
import Testing
import Axoloty

@Suite("Host typed IO")
struct AxolotyRuntimeIoTests {
    @Test("builder seals typed and dynamic endpoint registrations")
    func builderRegistration() throws {
        let identity = try RuntimeIdentity(
            id: ObjectID(bytes: ByteSlice(bytes: "00000000-0000-4000-8000-000000000091", length: 36))!.uuid,
            name: "host-io"
        )
    var builder = try RuntimeBuilder(identity: identity, namespace: "host-io")
        let sourceJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000092\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
        let actorJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000093\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
        let source = try builder.ioSource(
            metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceJSON.utf8Start,
                length: sourceJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        )
        let actor = try builder.ioActor(
            metadata: try Object<IoActorMetadata>(decoding: ByteSlice(
                bytes: actorJSON.utf8Start,
                length: actorJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        ) { _, _ in }
        let sealed = try builder.finish()
        #expect(sealed.ioEndpointCount == 2)
        #expect(source.id != actor.id)
    }

    @Test("catalogue capacity bounds endpoint registration")
    func catalogueCapacity() throws {
        let identity = try RuntimeIdentity(
            id: ObjectID(bytes: ByteSlice(bytes: "00000000-0000-4000-8000-0000000000a1", length: 36))!.uuid,
            name: "catalogue-limit"
        )
        let capacities = try RuntimeCapacities(ioEndpoints: 64, ioCatalogue: 1)
    var builder = try RuntimeBuilder(
            identity: identity,
            namespace: "catalogue-limit",
            capacities: capacities
        )
        func metadata(_ id: StaticString) throws -> Object<IoSourceMetadata> {
            try Object<IoSourceMetadata>(decoding: ByteSlice(bytes: id.utf8Start, length: id.utf8CodeUnitCount))
        }
        _ = try builder.ioSource(
            metadata: metadata("{\"objectId\":\"00000000-0000-4000-8000-0000000000a2\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"),
            as: Bool.self
        )
        do {
            _ = try builder.ioSource(
                metadata: metadata("{\"objectId\":\"00000000-0000-4000-8000-0000000000a3\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"),
                as: Bool.self
            )
            Issue.record("second endpoint exceeded the configured catalogue capacity")
        } catch {
            guard case let AxolotyError.caught(underlying) = error,
                  let protocolError = underlying as? ProtocolError else {
                Issue.record("catalogue saturation did not preserve ProtocolError")
                return
            }
            #expect(protocolError.code == .capacityExceeded)
        }
    }

    @Test("host IO lifecycle publishes endpoint advertisements and deadvertisements")
    func endpointLifecycleWirePublications() async throws {
        let identity = try RuntimeIdentity(
            id: ObjectID(bytes: ByteSlice(bytes: "00000000-0000-4000-8000-0000000000b1", length: 36))!.uuid,
            name: "host-io-wire"
        )
    var builder = try RuntimeBuilder(identity: identity, namespace: "host-io-wire")
        let sourceID = "00000000-0000-4000-8000-0000000000b2"
        let actorID = "00000000-0000-4000-8000-0000000000b3"
        let sourceJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-0000000000b2\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
        let actorJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-0000000000b3\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
        let sourceHandle = try builder.ioSource(
            metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
                bytes: sourceJSON.utf8Start,
                length: sourceJSON.utf8CodeUnitCount
            )),
            as: Bool.self,
            externalRoute: try MQTTExternalIoRoute("plant/line-7/temperature")
        )
        let actorHandle = try builder.ioActor(
            metadata: try Object<IoActorMetadata>(decoding: ByteSlice(
                bytes: actorJSON.utf8Start,
                length: actorJSON.utf8CodeUnitCount
            )),
            as: Bool.self
        ) { _, _ in }
        let transport = IoWireRecordingTransport()
        let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)

        try await runtime.start()
        let startup = await transport.publications()
        #expect(startup.contains { $0.routingKey.capability == .advertise })
        #expect(startup.contains { String(decoding: $0.payload, as: UTF8.self).contains(sourceID) })
        #expect(startup.contains { String(decoding: $0.payload, as: UTF8.self).contains(actorID) })
        #expect(startup.contains {
            String(decoding: $0.payload, as: UTF8.self)
                .contains(#""externalRoute":"plant/line-7/temperature""#)
        })

        await runtime.stop()
        let shutdown = await transport.publications()
        #expect(shutdown.count > startup.count)
        #expect(shutdown.contains { $0.routingKey.capability == .deadvertise })
        #expect(sourceHandle.id != actorHandle.id)
    }
}

private actor IoWireRecordingTransport: AxolotyRuntimeTransport {
    private var sent: [OwnedProtocolPublication] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async {}
    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        if case .publish(let publication) = effect { sent.append(publication) }
    }
    func stop() async {}
    func installSubscriptions(namespace: String) async throws {}
    func removeSubscriptions(namespace: String) async throws {}
    func publications() -> [OwnedProtocolPublication] { sent }
}
