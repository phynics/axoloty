// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Public Axoloty/1 consumer compiled with the complete portable Core graph and
// no `_JSONCore` module. This exercises bounded object materialization and the
// shared static protocol processor through its selected CBOR codec.

import AxolotyCoatyModels
#if CBOR_CORE_INTERNAL_TESTS
@testable import AxolotyObjectModel
#else
import AxolotyObjectModel
#endif
import AxolotyProtocol
import AxolotyStaticRuntime
import AxolotyWire

@main
struct EmbeddedCBORCoreConsumerProbe {
    static func main() {
        let objectBytes: [UInt8] = [
            0xA1, 0x64, 0x6E, 0x61, 0x6D, 0x65, 0x63, 0x63, 0x61, 0x74,
        ]
        let objectStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: objectBytes.count)
        objectStorage.initialize(from: objectBytes, count: objectBytes.count)
        defer {
            objectStorage.deinitialize(count: objectBytes.count)
            objectStorage.deallocate()
        }
        let object = try! BoundedCBORObject<64, 4>(decoding: ByteSlice(
            bytes: UnsafePointer(objectStorage),
            length: objectBytes.count
        ))
        precondition(object.count == 1)
        var name: [UInt8] = []
        precondition(object.withValue(for: "name") { name = $0.ownedBytes() })
        precondition(name == [0x63, 0x63, 0x61, 0x74])

        let idText: StaticString = "00000000-0000-4000-8000-000000000001"
        let idBytes = ByteSlice(bytes: idText.utf8Start, length: idText.utf8CodeUnitCount)
        let source = UUID16(parsing: idBytes)!
        let operationPayload: [UInt8] = [
            0xA1, 0x66, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74,
            0xA4,
            0x64, 0x6E, 0x61, 0x6D, 0x65, 0x61, 0x6E,
            0x68, 0x63, 0x6F, 0x72, 0x65, 0x54, 0x79, 0x70, 0x65, 0x6B,
            0x43, 0x6F, 0x61, 0x74, 0x79, 0x4F, 0x62, 0x6A, 0x65, 0x63, 0x74,
            0x68, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74, 0x49, 0x64,
            0xD8, 0x25, 0x50,
            0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11,
            0x81, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
            0x6A, 0x6F, 0x62, 0x6A, 0x65, 0x63, 0x74, 0x54, 0x79, 0x70, 0x65,
            0x78, 0x1A,
            0x63, 0x6F, 0x6D, 0x2E, 0x63, 0x6F, 0x61, 0x74, 0x79, 0x2E,
            0x74, 0x65, 0x73, 0x74, 0x2E, 0x57, 0x69, 0x72, 0x65, 0x46, 0x69,
            0x78, 0x74, 0x75, 0x72, 0x65,
        ]
        var runtime = try! StaticRuntime<2, 256>(
            registryID: ObjectID(uuid: source),
            wireCodec: WireCodec(profile: .axoloty1CBOR)
        )
        let result = operationPayload.withUnsafeBufferPointer { buffer in
            let operation = try! ProtocolLocalOperation(
                capability: .advertise,
                sourceID: source,
                payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count)
            )
            return runtime.send(operation)
        }
        precondition(result == .accepted)
        precondition(runtime.state.activeObjects == 1)
        precondition(runtime.actionCount == 2)
        _ = runtime.drain { _ in }
        checkFamilyExchanges(operationPayload, source: source)
        checkJSONOnlyFailures()
    }
}

private func checkJSONOnlyFailures() {
    let text: StaticString = "{}"
    let bytes = ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
    let json = WireCodec(profile: .coaty3JSON)
    let reader = json.reader(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
    do throws(WireDecodeError) {
        try reader.validate()
        preconditionFailure("JSON reader unexpectedly validated without _JSONCore")
    } catch { expectInvalidWireValue(error) }
    precondition(reader.readField("name") == nil)
    precondition(!json.isValidBareValue(bytes))
    var decoded = InlineArray<8, UInt8>(repeating: 0)
    do throws(WireDecodeError) {
        _ = try json.copyDecodedString(bytes, into: &decoded)
        preconditionFailure("JSON string decoding unexpectedly succeeded")
    } catch { expectInvalidWireValue(error) }

    let topic: StaticString = "coaty/3/probe/DSC/00000000-0000-4000-8000-000000000001/00000000-0000-4000-8000-000000000002"
    let message = BorrowedMessage(
        topicBytes: topic.utf8Start, topicLength: topic.utf8CodeUnitCount,
        payloadBytes: text.utf8Start, payloadLength: text.utf8CodeUnitCount
    )
    var messageWorkspace = EmbeddedWireParserWorkspace()
    for mode in 0..<4 {
        do throws(WireDecodeError) {
            switch mode {
            case 0: try message.reader().validate()
            case 1: try message.reader(workspace: &messageWorkspace).validate()
            case 2: _ = try message.ownedEvent()
            default: _ = try BorrowedWireEvent(message: message)
            }
            preconditionFailure("JSON borrowed-message decoding unexpectedly succeeded")
        } catch { expectInvalidWireValue(error) }
    }

    var jsonRuntime = try! StaticRuntime<2, 256>(registryID: ObjectID(uuid: .zero))
    let correlation = UUID16(parsing: probeBytes("22222222-2222-4222-8222-222222222222"))!
    precondition(jsonRuntime.send(.discover(
        sourceID: .zero, correlationID: correlation, payload: bytes, requestTimeoutMS: nil
    )) == .rejected(.malformedPayload))
    precondition(jsonRuntime.state.pendingCorrelations == 0 && jsonRuntime.actionCount == 0)
    precondition(jsonRuntime.send(.ioValue(sourceID: .zero, payload: bytes)) == .rejected(.malformedPayload))
    precondition(jsonRuntime.actionCount == 0)

    expectObjectFailure(.invalidEnvelope) { () throws(ObjectError) in
        _ = try ObjectEnvelope<32, 32>(decoding: bytes)
    }
    var workspace = EmbeddedWireParserWorkspace()
    expectObjectFailure(.invalidEnvelope) { () throws(ObjectError) in
        _ = try ObjectEnvelope<32, 32>(decoding: bytes, workspace: &workspace)
    }
    expectObjectFailure(.invalidObject) { () throws(ObjectError) in
        _ = try BoundedDynamicObject<512, 8>(decoding: bytes)
    }
    expectObjectFailure(.invalidObject) { () throws(ObjectError) in
        _ = try BoundedDynamicObject<512, 8>(decoding: text.utf8Start, length: text.utf8CodeUnitCount)
    }
    expectObjectFailure(.invalidObject) { () throws(ObjectError) in
        _ = try BoundedObject<CoatyObject, 512, 8>(decoding: bytes)
    }
    let envelope = try! ObjectEnvelope<32, 32>(
        objectID: ObjectID(uuid: .zero), objectType: CoatyObject.schema.objectType,
        name: BoundedEncodedText<32>("sensor")!, coreType: .coatyObject
    )
    // This is the constructor reported to panic on ESP32-C6 in issue #1057.
    expectObjectFailure(.invalidObject) { () throws(ObjectError) in
        _ = try BoundedObject<CoatyObject, 512, 8>(envelope: envelope, fields: CoatyObject())
    }
    expectObjectFailure(.invalidObject) { () throws(ObjectError) in
        _ = try Object<CoatyObject>(envelope: envelope, fields: CoatyObject())
    }
    #if CBOR_CORE_INTERNAL_TESTS
    // A public CBOR-only caller cannot construct a JSON ObjectFields value.
    // Exercise each decoder directly as well, so future construction paths
    // cannot reintroduce the trap or silently supply optional/default values.
    let decoder = ObjectFieldDecoder(bytes: UnsafeRawPointer(text.utf8Start), length: text.utf8CodeUnitCount)
    for mode in 0..<4 {
        do throws(ObjectDecodingError) {
            switch mode {
            case 0: _ = try decoder.decode("value", as: Bool.self)
            case 1: _ = try decoder.decodeIfPresent("value", as: Bool.self)
            case 2: _ = try decoder.decodeWithDefault("value", as: Bool.self, default: false)
            default: _ = try decoder.presence("value", as: Bool.self)
            }
            preconditionFailure("JSON field decoding unexpectedly succeeded")
        } catch { precondition(error == .invalidField) }
    }
    #endif
}

private func expectObjectFailure(
    _ reason: ObjectError.Reason,
    _ body: () throws(ObjectError) -> Void
) {
    do throws(ObjectError) {
        try body()
        preconditionFailure("JSON object operation unexpectedly succeeded")
    } catch { precondition(error.reason == reason) }
}

private func checkFamilyExchanges(_ advertise: [UInt8], source: UUID16) {
    let codec = WireCodec(profile: .axoloty1CBOR)
    var caller = try! StaticRuntime<4, 512>(registryID: ObjectID(uuid: source), wireCodec: codec)
    var peer = try! StaticRuntime<4, 512>(registryID: ObjectID(uuid: .zero), wireCodec: codec)
    let discovery = UUID16(parsing: probeBytes("22222222-2222-4222-8222-222222222222"))!
    let update = UUID16(parsing: probeBytes("33333333-3333-4333-8333-333333333333"))!
    for capability: ProtocolCapability in [.advertise, .channel, .discover, .resolve, .update, .complete, .deadvertise] {
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        var writer = codec.writer(buffer: storage, capacity: 512)
        try! writer.beginObject()
        switch capability {
        case .discover:
            try! writer.writeStringField("externalId", probeBytes("sensor-1"))
        case .deadvertise:
            let ids = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
            defer { ids.deallocate() }
            var array = codec.writer(buffer: ids, capacity: 32)
            try! array.beginArray()
            try! array.writeUUIDValue(UUID16(parsing: probeBytes("11111111-1111-4111-8111-111111111111"))!)
            try! array.endArray()
            try! writer.writeRawField("objectIds", ByteSlice(bytes: ids, length: array.position))
        default:
            advertise.withUnsafeBufferPointer { buffer in
                let reader = codec.reader(bytes: buffer.baseAddress!, length: buffer.count)
                try! writer.writeRawField("object", reader.readField("object")!)
            }
        }
        try! writer.endObject()
        let payload = Array(UnsafeBufferPointer(start: storage, count: writer.position))
        storage.deallocate()
        let correlation: UUID16?
        switch capability {
        case .discover, .resolve: correlation = discovery
        case .update, .complete: correlation = update
        default: correlation = nil
        }
        let isResponse = capability == .resolve || capability == .complete
        if isResponse {
            exchangeCBOR(capability, payload: payload, correlation: correlation, source: .zero, sender: &peer, receiver: &caller)
        } else {
            exchangeCBOR(capability, payload: payload, correlation: correlation, source: source, sender: &caller, receiver: &peer)
        }
        switch capability {
        case .advertise, .channel:
            precondition(caller.state.activeObjects == 1 && peer.state.activeObjects == 1)
        case .discover, .resolve:
            precondition(caller.state.pendingCorrelations == 1)
        case .update:
            precondition(caller.state.pendingCorrelations == 2)
        case .complete:
            precondition(caller.state.pendingCorrelations == 1)
        case .deadvertise:
            precondition(caller.state.activeObjects == 0 && peer.state.activeObjects == 0)
        default: preconditionFailure("Unexpected probe capability")
        }
    }
    precondition(caller.cancel(correlationID: discovery))
}

private func exchangeCBOR(
    _ capability: ProtocolCapability, payload: [UInt8], correlation: UUID16?, source: UUID16,
    sender: inout StaticRuntime<4, 512>, receiver: inout StaticRuntime<4, 512>
) {
    payload.withUnsafeBufferPointer { buffer in
        let operation = try! ProtocolLocalOperation(
            capability: capability, sourceID: source, correlationID: correlation,
            payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count),
            operationName: capability == .channel ? probeBytes("readings") : nil
        )
        precondition(sender.send(operation) == .accepted)
    }
    var publications: [OwnedProtocolPublication] = []
    sender.drain { action in
        if case .publish(let publication) = action, publication.isApplicationDelivery {
            publications.append(publication.owned())
        }
    }
    precondition(publications.count == 1)
    for publication in publications {
        precondition(publication.payload == payload)
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        defer { storage.deallocate() }
        var topic = TopicBuilder(buffer: storage, capacity: 256)
        try! topic.writePrefix(.axoloty1CBOR)
        try! topic.writeNamespace("cbor-probe")
        guard case .profile(let filter, let kind) = publication.target else {
            preconditionFailure("Expected a profile route")
        }
        if let filter {
            filter.withUnsafeBufferPointer { buffer in
                try! topic.writeEventType(
                    capability.wireEventType,
                    filter: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count),
                    filterKind: kind == .objectType ? .objectType : .direct
                )
            }
        } else { try! topic.writeEventType(capability.wireEventType) }
        try! topic.writeSourceId(source)
        if let correlation { try! topic.writeCorrelationId(correlation) }
        payload.withUnsafeBufferPointer { buffer in
            precondition(receiver.receive(
                topic: topic.build(), payload: ByteSlice(bytes: buffer.baseAddress!, length: buffer.count), nowMS: 1
            ) == .accepted)
        }
        var deliveries = 0
        receiver.drain { action in
            if case .deliver(let delivery) = action {
                precondition(delivery.routingKey.capability == capability)
                precondition(delivery.routingKey.correlationID == correlation)
                precondition(delivery.payload.ownedBytes() == payload)
                deliveries += 1
            }
        }
        precondition(deliveries == 1)
    }
}

private func probeBytes(_ text: StaticString) -> ByteSlice {
    ByteSlice(bytes: text.utf8Start, length: text.utf8CodeUnitCount)
}

private func expectInvalidWireValue(_ error: WireDecodeError) {
    guard case .invalidValue = error.reason else {
        preconditionFailure("Unexpected wire decode failure")
    }
}
