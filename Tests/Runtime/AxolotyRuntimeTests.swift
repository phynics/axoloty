// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import Axoloty
import AxolotyProtocol
import AxolotyWire

@Suite("Axoloty runtime")
struct AxolotyRuntimeTests {
    @Test("definition seals a finite handler set")
    func definitionSealsHandlers() throws {
        let capacities = try RuntimeCapacities(handlers: 1)
        var definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: capacities
        )
        _ = try definition.register(capability: .ioValue) { _ in .noResponse }
        let sealed = try definition.seal()
        #expect(sealed.capacities.handlers == 1)
        #expect(sealed.handlerCount == 1)
    }

    @Test("runtime rejects work before start")
    func rejectsBeforeStart() async throws {
        let definition = try makeDefinition()
        let runtime = AxolotyRuntime(definition: definition, transport: TestTransport())
        let receipt = await runtime.receive(RuntimeInboundFrame(topic: "coaty/3/test/IOV/00000000-0000-0000-0000-000000000000", payload: [0x7B, 0x7D]))
        #expect(receipt == .rejected(.notRunning(.stopped)))
    }

    @Test("runtime uses the shared processor for an accepted local operation")
    func acceptsLocalOperation() async throws {
        let definition = try makeDefinition()
        let transport = TestTransport()
        let runtime = AxolotyRuntime(definition: definition, transport: transport)
        try await runtime.start()

        let receipt = await runtime.publish(
            RuntimeOperation(
                capability: .ioValue,
                sourceID: .zero,
                payload: [0x7B, 0x7D]
            )
        )
        #expect(receipt == .accepted)
        for _ in 0..<100 {
            if await transport.sentCount() == 1 { break }
            await Task.yield()
        }
        #expect(await transport.sentCount() == 1)
        await runtime.stop()
    }

    private func makeDefinition() throws -> SealedRuntimeDefinition {
        let definition = try RuntimeDefinition(
            namespace: "test",
            sourceID: .zero,
            capacities: try RuntimeCapacities()
        )
        return try definition.seal()
    }
}

private actor TestTransport: AxolotyRuntimeTransport {
    private var receive: (@Sendable (RuntimeInboundFrame) -> Void)?
    private var sent: [OwnedProtocolAction] = []

    func start(receive: @escaping @Sendable (RuntimeInboundFrame) -> Void) async throws {
        self.receive = receive
    }

    func send(_ action: OwnedProtocolAction, namespace: String) async throws {
        sent.append(action)
    }

    func stop() async {
        receive = nil
    }

    func sentCount() -> Int { sent.count }
}
