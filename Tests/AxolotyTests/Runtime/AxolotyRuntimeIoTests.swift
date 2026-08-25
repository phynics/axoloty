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
        var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "host-io")
        let sourceJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000092\",\"objectType\":\"coaty.IoSource\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"
        let actorJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000093\",\"objectType\":\"coaty.IoActor\",\"coreType\":\"IoActor\",\"valueType\":\"com.example.Bool\"}"
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
        var builder = try RuntimeDefinition.Builder(
            identity: identity,
            namespace: "catalogue-limit",
            capacities: capacities
        )
        func metadata(_ id: StaticString) throws -> Object<IoSourceMetadata> {
            try Object<IoSourceMetadata>(decoding: ByteSlice(bytes: id.utf8Start, length: id.utf8CodeUnitCount))
        }
        _ = try builder.ioSource(
            metadata: metadata("{\"objectId\":\"00000000-0000-4000-8000-0000000000a2\",\"objectType\":\"coaty.IoSource\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"),
            as: Bool.self
        )
        do {
            _ = try builder.ioSource(
                metadata: metadata("{\"objectId\":\"00000000-0000-4000-8000-0000000000a3\",\"objectType\":\"coaty.IoSource\",\"coreType\":\"IoSource\",\"valueType\":\"com.example.Bool\"}"),
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
}
