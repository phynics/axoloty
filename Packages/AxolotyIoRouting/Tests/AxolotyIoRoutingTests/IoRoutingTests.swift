// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyIoRouting
import Axoloty
import AxolotyObjectModel
import AxolotyProtocol
import AxolotyWire
import Testing

@Test("Basic routing limits use the bounded host defaults")
func basicRoutingLimitsDefaultToBoundedCapacity() {
    let limits = IoRoutingLimits()
    #expect(limits.maximumEndpoints == 64)
    #expect(limits.maximumAssociations == 64)
}

@Test("Basic routing limits retain explicit bounded values")
func basicRoutingLimitsRetainValues() {
    let limits = IoRoutingLimits(maximumEndpoints: 4, maximumAssociations: 7)
    #expect(limits == IoRoutingLimits(maximumEndpoints: 4, maximumAssociations: 7))
}

@Test("Basic routing matches scoped endpoints and emits a stable association")
func basicRoutingMatchesScopedEndpoints() async throws {
    let externalRoute = "gnostic/1/workspaces/11111111-1111-4111-8111-111111111111/agents/22222222-2222-4222-8222-222222222222/tools/33333333-3333-4333-8333-333333333333/requests"
    #expect(externalRoute.utf8.count > 128)
    #expect(externalRoute.utf8.count <= WireBufferConfig.maxTopicLength)
    let identity = try RuntimeIdentity(
        id: objectID("00000000-0000-4000-8000-000000000101").uuid,
        name: "routing-test"
    )
    var builder = try RuntimeDefinition.Builder(identity: identity, namespace: "routing-test")
    let contextJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000102\",\"objectType\":\"coaty.IoContext\",\"name\":\"context\",\"coreType\":\"IoContext\"}"
    let sourceJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000103\",\"objectType\":\"coaty.IoSource\",\"name\":\"source\",\"coreType\":\"IoSource\",\"parentObjectId\":\"00000000-0000-4000-8000-000000000102\",\"valueType\":\"com.example.Bool\",\"externalRoute\":\"gnostic/1/workspaces/11111111-1111-4111-8111-111111111111/agents/22222222-2222-4222-8222-222222222222/tools/33333333-3333-4333-8333-333333333333/requests\"}"
    let actorJSON: StaticString = "{\"objectId\":\"00000000-0000-4000-8000-000000000104\",\"objectType\":\"coaty.IoActor\",\"name\":\"actor\",\"coreType\":\"IoActor\",\"parentObjectId\":\"00000000-0000-4000-8000-000000000102\",\"valueType\":\"com.example.Bool\"}"
    let context = try Object<IoContext>(decoding: ByteSlice(
        bytes: contextJSON.utf8Start,
        length: contextJSON.utf8CodeUnitCount
    ))
    let source = try builder.ioSource(
        metadata: try Object<IoSourceMetadata>(decoding: ByteSlice(
            bytes: sourceJSON.utf8Start,
            length: sourceJSON.utf8CodeUnitCount
        )),
        as: Bool.self,
        externalRoute: try MQTTExternalIoRoute(externalRoute)
    )
    let actor = try builder.ioActor(
        metadata: try Object<IoActorMetadata>(decoding: ByteSlice(
            bytes: actorJSON.utf8Start,
            length: actorJSON.utf8CodeUnitCount
        )),
        as: Bool.self
    ) { _, _ in }
    try builder.basicIoRouting(context: context)
    let transport = RoutingRecordingTransport()
    let runtime = AxolotyRuntime(definition: try builder.finish(), transport: transport)

    try await runtime.start()
    let association = await transport.waitForPublication(containing: externalRoute)
    #expect(association)
    #expect(source.id != actor.id)
    await runtime.stop()
}

private func objectID(_ value: StaticString) -> ObjectID {
    ObjectID(bytes: ByteSlice(bytes: value.utf8Start, length: value.utf8CodeUnitCount))!
}

private actor RoutingRecordingTransport: AxolotyRuntimeTransport {
    private var publications: [[UInt8]] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {}
    func perform(_ effect: RuntimeTransportEffect, namespace: String) async throws {
        guard case .publish(let publication) = effect else { return }
        publications.append(publication.payload)
    }
    func stop() async {}
    func waitForPublication(containing text: String) async -> Bool {
        for _ in 0..<100 {
            if publications.contains(where: { String(decoding: $0, as: UTF8.self).contains(text) }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
