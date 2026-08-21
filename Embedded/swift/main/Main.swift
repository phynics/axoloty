// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Embedded Swift entry point for ESP32-C6 (issues #321, #322).
//
// Runs AxolotyWire test vectors on-device using the real Swift wire codec.
// Emits structured JSON Lines records over serial. The host harness parses
// these records and validates their evidence chain.
//
// Success is NEVER emitted before all checks complete.

import AxolotyWire
import AxolotyProtocol

private struct UnsafeSendablePointer<Pointee>: @unchecked Sendable {
    let value: UnsafeMutablePointer<Pointee>
}

@_cdecl("app_main")
func app_main() -> Int32 {
    let schemaVersion: UInt32 = 2
    let runId: StaticString = "embedded-swift-smoke-v2"
    var sequence: UInt32 = 0
    var rollingChecksum: UInt32 = 0
    var passed: UInt32 = 0
    var failed: UInt32 = 0
    guard axoloty_protocol_embedded_link_probe() == 3 else {
        return 1
    }
    let networkRole = axoloty_network_role()
    let networkScenario = axoloty_network_scenario()
    var emittingExchangeEvidence = false

    @inline(__always)
    func printStatic(_ value: StaticString) {
        axoloty_print(
            UnsafeRawPointer(value.utf8Start).assumingMemoryBound(to: CChar.self)
        )
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ byte: UInt8) -> UInt32 {
        (hash ^ UInt32(byte)) &* 16777619
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ value: StaticString) -> UInt32 {
        var result = hash
        let bytes = value.utf8Start
        for index in 0..<value.utf8CodeUnitCount {
            result = mix(result, UInt8(bytes[index]))
        }
        return result
    }

    @inline(__always)
    func mix(_ hash: UInt32, _ value: UInt32) -> UInt32 {
        var result = hash
        result = mix(result, UInt8(truncatingIfNeeded: value))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 8))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 16))
        result = mix(result, UInt8(truncatingIfNeeded: value >> 24))
        return result
    }

    @inline(__always)
    func nextChecksum(_ caseId: StaticString, _ operation: StaticString,
                      _ stage: StaticString,
                      _ status: StaticString, _ prior: UInt32,
                      _ currentSequence: UInt32, _ currentPassed: UInt32 = 0,
                      _ currentFailed: UInt32 = 0) -> UInt32 {
        var result: UInt32 = 2166136261
        result = mix(result, schemaVersion)
        result = mix(result, runId)
        result = mix(result, currentSequence)
        result = mix(result, caseId)
        result = mix(result, operation)
        result = mix(result, stage)
        result = mix(result, status)
        result = mix(result, currentPassed)
        result = mix(result, currentFailed)
        return mix(result, prior)
    }

    @inline(__always)
    func printPrefix(_ caseId: StaticString, _ operation: StaticString,
                     _ stage: StaticString,
                     _ status: StaticString, _ checksum: UInt32) {
        axoloty_print("{\"schemaVersion\":2,\"runId\":\"")
        printStatic(runId)
        axoloty_print("\",\"sequence\":")
        axoloty_print_uint("", sequence)
        axoloty_print(",\"caseId\":\"")
        printStatic(caseId)
        axoloty_print("\",\"operation\":\"")
        printStatic(operation)
        axoloty_print("\",\"stage\":\"")
        printStatic(stage)
        axoloty_print("\",\"status\":\"")
        printStatic(status)
        axoloty_print("\",\"checksum\":")
        axoloty_print_uint("", checksum)
    }

    rollingChecksum = nextChecksum("boot", "boot", "boot", "started", 0, sequence)
    printPrefix("boot", "boot", "boot", "started", rollingChecksum)
    axoloty_print("}\n")
    sequence &+= 1
    vTaskDelay(1)

    @inline(__always)
    func record(_ name: StaticString, _ ok: Bool) {
        if networkRole != 0 && !emittingExchangeEvidence { return }
        let status: StaticString = ok ? "passed" : "failed"
        let checksum = nextChecksum(name, "smokeCheck", "execute", status, rollingChecksum, sequence)
        printPrefix(name, "smokeCheck", "execute", status, checksum)
        if !ok {
            axoloty_print(",\"diagnostic\":\"failed check: ")
            printStatic(name)
            axoloty_print("\"")
        }
        axoloty_print("}\n")
        vTaskDelay(1)
        rollingChecksum = checksum
        sequence &+= 1
        if ok {
            passed &+= 1
        } else {
            failed &+= 1
        }
    }

    // Vector checks deliberately use the production APIs and fixed storage.
    // The identifiers below are also the stable corpus consumed by the host
    // validator; keep additions deterministic and grouped by category.
    @inline(__always)
    func reader(_ payload: StaticString) -> WireReader {
        WireReader(bytes: payload.utf8Start, length: payload.utf8CodeUnitCount)
    }

    @inline(__always)
    func writeIntVector(_ id: StaticString, _ value: Int, _ expected: StaticString) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { storage in
            var writer = WireWriter(buffer: storage.baseAddress!, capacity: storage.count)
            var ok = (try? writer.writeInt(value)) != nil
            if ok && writer.position == expected.utf8CodeUnitCount {
                for index in 0..<writer.position where storage[index] != expected.utf8Start[index] { ok = false }
            } else { ok = false }
            record(id, ok)
        }
    }

    @inline(__always)
    func topicVector(_ id: StaticString, _ capacity: Int, _ suffix: StaticString, _ shouldFit: Bool) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 129) { storage in
            var builder = TopicBuilder(buffer: storage.baseAddress!, capacity: capacity)
            var ok = (try? builder.writePrefix()) != nil
            if ok { ok = (try? builder.writeNamespace("ns")) != nil }
            if ok { ok = (try? builder.writeEventType(.advertise)) != nil }
            if ok { ok = (try? builder.writeSourceId(UUID16.zero)) != nil }
            if ok && suffix.utf8CodeUnitCount > 0 {
                ok = (try? builder.writeCorrelationId(UUID16.zero)) != nil
            }
            record(id, ok == shouldFit)
        }
    }

    @inline(__always)
    func boundedVector(_ id: StaticString, _ topicLength: Int, _ payloadLength: Int, _ shouldFit: Bool) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 513) { payload in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 130) { topic in
                let ok = (try? BorrowedMessage.validated(
                    topicBytes: topic.baseAddress!, topicLength: topicLength,
                    payloadBytes: payload.baseAddress!, payloadLength: payloadLength
                )) != nil
                record(id, ok == shouldFit)
            }
        }
    }

    // === Topic parse tests ===

    let tADV: StaticString = "coaty/3/ns/ADV/source-id"
    let tvADV = TopicView(topicBytes: tADV.utf8Start, length: tADV.utf8CodeUnitCount)
    record("topicParse:ADV", tvADV.eventType == .advertise)

    let tDAD: StaticString = "coaty/3/ns/DAD/source-id"
    let tvDAD = TopicView(topicBytes: tDAD.utf8Start, length: tDAD.utf8CodeUnitCount)
    record("topicParse:DAD", tvDAD.eventType == .deadvertise)

    let tDSC: StaticString = "coaty/3/ns/DSC/source-id/corr-id"
    let tvDSC = TopicView(topicBytes: tDSC.utf8Start, length: tDSC.utf8CodeUnitCount)
    record("topicParse:DSC", tvDSC.eventType == .discover)

    let tRSV: StaticString = "coaty/3/ns/RSV/source-id/corr-id"
    let tvRSV = TopicView(topicBytes: tRSV.utf8Start, length: tRSV.utf8CodeUnitCount)
    record("topicParse:RSV", tvRSV.eventType == .resolve)

    let tCHN: StaticString = "coaty/3/ns/CHN:channel-id/source-id"
    let tvCHN = TopicView(topicBytes: tCHN.utf8Start, length: tCHN.utf8CodeUnitCount)
    record("topicParse:CHN", tvCHN.eventType == .channel)

    let tASC: StaticString = "coaty/3/ns/ASC:filter/source-id"
    let tvASC = TopicView(topicBytes: tASC.utf8Start, length: tASC.utf8CodeUnitCount)
    record("topicParse:ASC", tvASC.eventType == .associate)

    let tIOV: StaticString = "coaty/3/ns/IOV/source-id"
    let tvIOV = TopicView(topicBytes: tIOV.utf8Start, length: tIOV.utf8CodeUnitCount)
    record("topicParse:IOV", tvIOV.eventType == .ioValue)

    let tRAW: StaticString = "some/random/topic"
    let tvRAW = TopicView(topicBytes: tRAW.utf8Start, length: tRAW.utf8CodeUnitCount)
    record("topicParse:raw", tvRAW.isRawTopic && tvRAW.eventType == nil)

    let tFILT: StaticString = "coaty/3/ns/ADV:Identity/src"
    let tvFILT = TopicView(topicBytes: tFILT.utf8Start, length: tFILT.utf8CodeUnitCount)
    record("topicParse:filter", tvFILT.eventType == .advertise && tvFILT.eventTypeFilter != nil)

    // === DTO decode tests ===

    let pADV: StaticString = #"{"object":{"objectId":"33333333-3333-4333-8333-333333333333","name":"test","objectType":"coaty.Identity","coreType":"Identity"}}"#
    let rADV = WireReader(bytes: pADV.utf8Start, length: pADV.utf8CodeUnitCount)
    record("dtoDecode:advertise", rADV.readRaw("object") != nil)

    let pUUID: StaticString = #"{"objectId":"33333333-3333-4333-8333-333333333333"}"#
    let rUUID = WireReader(bytes: pUUID.utf8Start, length: pUUID.utf8CodeUnitCount)
    record("dtoDecode:uuid", rUUID.readUUID("objectId") != nil)

    let pINT: StaticString = #"{"updateRate":100}"#
    let rINT = WireReader(bytes: pINT.utf8Start, length: pINT.utf8CodeUnitCount)
    record("dtoDecode:int", rINT.readInt("updateRate") == 100)

    let pBOOL: StaticString = #"{"hasAssociations":true}"#
    let rBOOL = WireReader(bytes: pBOOL.utf8Start, length: pBOOL.utf8CodeUnitCount)
    record("dtoDecode:bool", rBOOL.readBool("hasAssociations") == true)

    let pMISS: StaticString = #"{"otherField":"value"}"#
    let rMISS = WireReader(bytes: pMISS.utf8Start, length: pMISS.utf8CodeUnitCount)
    record("dtoDecode:missingField", rMISS.readString("name") == nil)

    // === Malformed input tests ===

    let pTRUNC: StaticString = #"{"objectId":"33333333"#
    let rTRUNC = WireReader(bytes: pTRUNC.utf8Start, length: pTRUNC.utf8CodeUnitCount)
    record("malformed:truncated", rTRUNC.readUUID("objectId") == nil)

    let pEMPTY: StaticString = ""
    let rEMPTY = WireReader(bytes: pEMPTY.utf8Start, length: 0)
    record("malformed:empty", rEMPTY.readString("field") == nil)

    let pBADUUID: StaticString = #"{"objectId":"not-a-uuid"}"#
    let rBADUUID = WireReader(bytes: pBADUUID.utf8Start, length: pBADUUID.utf8CodeUnitCount)
    record("malformed:invalidUUID", rBADUUID.readUUID("objectId") == nil)

    // === UUID16 tests ===

    let uuidStr: StaticString = "33333333-3333-4333-8333-333333333333"
    let uuidSlice = ByteSlice(bytes: uuidStr.utf8Start, length: 36)
    record("uuid16:parseValid", UUID16(parsing: uuidSlice) != nil)

    let badUuidStr: StaticString = "not-a-uuid"
    let badUuidSlice = ByteSlice(bytes: badUuidStr.utf8Start, length: 10)
    record("uuid16:parseInvalid", UUID16(parsing: badUuidSlice) == nil)

    record("uuid16:zero", UUID16.zero == UUID16(bytes: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))

    // === Config tests ===

    record("config:payloadMax512", WireBufferConfig.maxPayloadSize == 512)
    record("config:topicMax128", WireBufferConfig.maxTopicLength == 128)
    record("config:maxSubscribers8", ProtocolBufferConfig.maxSubscribers == 8)
    record("config:maxFamilyEntries16", ProtocolBufferConfig.maxFamilyEntries == 16)

    // === Deterministic vector corpus ===
    writeIntVector("writer:zero", 0, "0")
    writeIntVector("writer:one", 1, "1")
    writeIntVector("writer:minusOne", -1, "-1")
    // ESP32-C6 Embedded Swift uses a 32-bit `Int`; keep these expectations
    // target-specific so the device vector detects a width-dependent encoding.
    writeIntVector("writer:max", Int.max, "2147483647")
    writeIntVector("writer:min", Int.min, "-2147483648")

    topicVector("topic:exact", 51, "", true)
    topicVector("topic:underCapacity", 50, "", false)
    topicVector("topic:overflow", 51, "corr", false)
    boundedVector("capacity:payload0", 0, 0, true)
    boundedVector("capacity:payload1", 0, 1, true)
    boundedVector("capacity:payload511", 0, 511, true)
    boundedVector("capacity:payload512", 0, 512, true)
    boundedVector("capacity:payload513", 0, 513, false)
    boundedVector("capacity:topic0", 0, 0, true)
    boundedVector("capacity:topic1", 1, 0, true)
    boundedVector("capacity:topic128", 128, 0, true)
    boundedVector("capacity:topic129", 129, 0, false)

    record("malformed:truncation", reader(#"{"objectId":"33333333"#).readUUID("objectId") == nil)
    record("malformed:corruption", reader(#"{"objectId":@}"#).readUUID("objectId") == nil)
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 12) { bytes in
        bytes[0] = 0x7B; bytes[1] = 0x22; bytes[2] = 0x6E; bytes[3] = 0x22
        bytes[4] = 0x3A; bytes[5] = 0x22; bytes[6] = 0xFF; bytes[7] = 0x22
        bytes[8] = 0x7D
        record("malformed:utf8", WireReader(bytes: bytes.baseAddress!, length: 9).readString("n") == nil)
    }
    record("malformed:escape", reader(#"{"name":"bad\q"}"#).readString("name") == nil)
    record("malformed:literal", reader(#"{"value":tru}"#).readBool("value") == nil)
    record("malformed:number", reader(#"{"value":1e}"#).readInt("value") == nil)
    record("malformed:missing", reader(#"{"other":1}"#).readString("name") == nil)
    record("malformed:unknown", reader(#"{"unknown":1}"#).readString("name") == nil)
    record("malformed:duplicate", reader(#"{"name":1,"name":2}"#).readString("name") != nil)
    record("malformed:reordered", reader(#"{"value":1,"name":"x"}"#).readString("name") != nil)
    record("malformed:trailing", reader(#"{"value":1}x"#).readInt("value") != nil)
    record("malformed:nesting", reader(#"{"value":{"x":[1,2]}}"#).readRaw("value") != nil)

    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 32) { payload in
        let rawMessage = BorrowedMessage(topicBytes: payload.baseAddress!, topicLength: 0,
                                         payloadBytes: payload.baseAddress!, payloadLength: 0)
        record("borrowed:topicView", rawMessage.isRawTopic)
        record("borrowed:reader", rawMessage.reader().length == 0)

        let discoverTopic: StaticString = "coaty/3/ns/DSC/source-id/correlation-id"
        let discoverMessage = BorrowedMessage(
            topicBytes: discoverTopic.utf8Start,
            topicLength: discoverTopic.utf8CodeUnitCount,
            payloadBytes: payload.baseAddress!,
            payloadLength: 0
        )
        let router = try! EmbeddedMessageRouter()
        withUnsafeTemporaryAllocation(of: Bool.self, capacity: 1) { dispatched in
            dispatched[0] = false
            let dispatchedPointer = UnsafeSendablePointer(value: dispatched.baseAddress!)
            let token = router.subscribe(.discover) { _ in dispatchedPointer.value.pointee = true }
            record("router:subscribe", token != nil)
            router.dispatch(discoverMessage)
            record("router:dispatch", dispatchedPointer.value.pointee)
        }
    }

    // === Static Phase 4 device agent ===

    let staticAgent = StaticDeviceAgent()
    record("agent:identity", StaticDeviceAgent.agentId != .zero &&
           StaticDeviceAgent.agentId != StaticDeviceAgent.deviceObjectId)

    @inline(__always)
    func agentVector(
        _ id: StaticString,
        topic: StaticString,
        payload: StaticString,
        expected: StaticDeviceDispatchResult
    ) {
        let message = try? BorrowedMessage.validated(
            topicBytes: topic.utf8Start, topicLength: topic.utf8CodeUnitCount,
            payloadBytes: payload.utf8Start, payloadLength: payload.utf8CodeUnitCount
        )
        record(id, message.map { staticAgent.dispatch($0, nowMS: 101) == expected } ?? false)
    }

    let expectedCorrelation = UUID16(bytes: (
        0x32, 0x40, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04
    ))
    agentVector(
        "agent:advertise",
        topic: "coaty/3/axoloty-embedded/ADV/32400000-0000-4000-8000-000000000003",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .advertise
    )
    let advertised = staticAgent.hasAdvertisedPeer
    agentVector(
        "agent:deadvertise",
        topic: "coaty/3/axoloty-embedded/DAD/32400000-0000-4000-8000-000000000003",
        payload: "{\"objectIds\":[\"32400000-0000-4000-8000-000000000003\"]}",
        expected: .deadvertise
    )
    record("agent:advertisedState", advertised && !staticAgent.hasAdvertisedPeer)
    agentVector(
        "agent:discover",
        topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectTypes\":[\"coaty.test.Device\"]}",
        expected: .discover
    )
    agentVector(
        "agent:discoverById",
        topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectId\":\"32400000-0000-4000-8000-000000000002\"}",
        expected: .discover
    )
    agentVector(
        "agent:rejectWrongFilter",
        topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"objectTypes\":[\"coaty.test.Other\"]}",
        expected: .unsupported
    )
    record("agent:beginDiscover", staticAgent.beginDiscover(correlationId: expectedCorrelation, nowMS: 100))
    record("agent:boundedOutstanding", !staticAgent.beginDiscover(correlationId: UUID16.zero, nowMS: 100))
    agentVector(
        "agent:wrongCorrelation",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000005",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .wrongCorrelation
    )
    agentVector(
        "agent:resolve",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .resolve
    )
    agentVector(
        "agent:duplicateResolve",
        topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004",
        payload: "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}",
        expected: .duplicateResolve
    )
    record("agent:beginTimedDiscover", staticAgent.beginDiscover(correlationId: UUID16.zero, nowMS: 100))
    record("agent:resolveTimeout", staticAgent.expireDiscover(nowMS: 5_100))

    @inline(__always)
    func receiveAgentMessage(topic: StaticString, payload: StaticString) -> Int32 {
        var result: Int32 = -1
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { outputTopic in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { outputPayload in
                withUnsafeTemporaryAllocation(of: Int32.self, capacity: 1) { outputTopicLength in
                    withUnsafeTemporaryAllocation(of: Int32.self, capacity: 1) { outputPayloadLength in
                        result = axolotyStaticAgentReceive(
                            2, topic.utf8Start, Int32(topic.utf8CodeUnitCount),
                            payload.utf8Start, Int32(payload.utf8CodeUnitCount),
                            outputTopic.baseAddress!, Int32(outputTopic.count),
                            outputPayload.baseAddress!, Int32(outputPayload.count),
                            outputTopicLength.baseAddress!, outputPayloadLength.baseAddress!
                        )
                    }
                }
            }
        }
        return result
    }
    let callbackAdvertiseTopic: StaticString = "coaty/3/axoloty-embedded/ADV/32400000-0000-4000-8000-000000000003"
    let callbackResolveTopic: StaticString = "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000003/32400000-0000-4000-8000-000000000004"
    let callbackPayload: StaticString = "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
    record("agent:callbackRejectUnsolicitedResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == -1)
    record("agent:callbackAdvertise", receiveAgentMessage(
        topic: callbackAdvertiseTopic, payload: callbackPayload
    ) == 1)
    record("agent:callbackResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == 2)
    record("agent:callbackRejectDuplicateResolve", receiveAgentMessage(
        topic: callbackResolveTopic, payload: callbackPayload
    ) == -1)

    let advertisePayload: StaticString = "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
    let advertiseData = try? AdvertiseWireData(from: WireReader(
        bytes: advertisePayload.utf8Start, length: advertisePayload.utf8CodeUnitCount
    ))
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { topicBuffer in
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { payloadBuffer in
            guard let advertiseData,
                  let encoded = try? staticAgent.encode(
                    advertiseData, eventType: .advertise, correlationId: nil,
                    topicBuffer: topicBuffer.baseAddress!, topicCapacity: topicBuffer.count,
                    payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: payloadBuffer.count
                  ) else {
                record("agent:fixedPublish", false)
                return
            }
            let topic = TopicView(topicBytes: topicBuffer.baseAddress!, length: encoded.topicLength)
            let decoded = try? AdvertiseWireData(from: WireReader(
                bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength
            ))
            record("agent:fixedPublish", topic.eventType == .advertise &&
                    topic.sourceIdLevel.flatMap(UUID16.init(parsing:)) == StaticDeviceAgent.agentId &&
                    decoded != nil && encoded.payloadLength <= WireBufferConfig.maxPayloadSize &&
                    ByteSlice(bytes: topicBuffer.baseAddress!, length: encoded.topicLength).equals(
                        "coaty/3/axoloty-embedded/ADV:coaty.test.Device/32400000-0000-4000-8000-000000000001"
                    ) && ByteSlice(bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength).equals(
                        "{\"object\":{\"objectId\":\"32400000-0000-4000-8000-000000000003\"}}"
                    ))
        }
    }
    @inline(__always)
    func matchesFixedWire<T: WireEncodable>(
        _ data: T,
        eventType: WireEventType,
        correlationId: UUID16?,
        topic expectedTopic: StaticString,
        payload expectedPayload: StaticString
    ) -> Bool {
        var matches = false
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { topicBuffer in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { payloadBuffer in
                guard let encoded = try? staticAgent.encode(
                    data, eventType: eventType, correlationId: correlationId,
                    topicBuffer: topicBuffer.baseAddress!, topicCapacity: topicBuffer.count,
                    payloadBuffer: payloadBuffer.baseAddress!, payloadCapacity: payloadBuffer.count
                ) else { return }
                matches = ByteSlice(bytes: topicBuffer.baseAddress!, length: encoded.topicLength).equals(expectedTopic) &&
                    ByteSlice(bytes: payloadBuffer.baseAddress!, length: encoded.payloadLength).equals(expectedPayload)
            }
        }
        return matches
    }
    let deadvertisePayload: StaticString = "{\"objectIds\":[\"32400000-0000-4000-8000-000000000003\"]}"
    let discoverPayload: StaticString = "{\"objectTypes\":[\"coaty.test.Device\"]}"
    let resolvePayload: StaticString = advertisePayload
    record("agent:fixedDeadvertise", (try? DeadvertiseWireData(from: WireReader(
        bytes: deadvertisePayload.utf8Start, length: deadvertisePayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .deadvertise, correlationId: nil,
                         topic: "coaty/3/axoloty-embedded/DAD/32400000-0000-4000-8000-000000000001",
                         payload: deadvertisePayload)
    } ?? false)
    record("agent:fixedDiscover", (try? DiscoverWireData(from: WireReader(
        bytes: discoverPayload.utf8Start, length: discoverPayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .discover, correlationId: expectedCorrelation,
                         topic: "coaty/3/axoloty-embedded/DSC/32400000-0000-4000-8000-000000000001/32400000-0000-4000-8000-000000000004",
                         payload: discoverPayload)
    } ?? false)
    record("agent:fixedResolve", (try? ResolveWireData(from: WireReader(
        bytes: resolvePayload.utf8Start, length: resolvePayload.utf8CodeUnitCount
    ))).map {
        matchesFixedWire($0, eventType: .resolve, correlationId: expectedCorrelation,
                         topic: "coaty/3/axoloty-embedded/RSV/32400000-0000-4000-8000-000000000001/32400000-0000-4000-8000-000000000004",
                         payload: resolvePayload)
    } ?? false)
    // === Generated 39-case benchmark corpus ===

    runGeneratedCorpus(record)

    // The ordinary vector image is deliberately credential-free. A dedicated
    // network build supplies the C-owned configuration and appends evidence
    // without changing the existing corpus or its counts.
    if axoloty_network_configured() != 0 {
        if networkRole == 0 {
            let networkBits = axoloty_network_prepare(90_000)
            record("network:wifi", (networkBits & 1) != 0)
            record("network:ip", (networkBits & 2) != 0)
            if (networkBits & 3) == 3 {
                var probe = EmbeddedMQTTClient()
                record("network:rejectOutOfOrder", !probe.disconnect())
                var client = EmbeddedMQTTClient()
                let willTopic: StaticString = "axoloty/network/will"
                let willPayload: StaticString = "axoloty-network-offline"
                let lastWillConfigured = client.configureLastWill(
                    topic: willTopic.utf8Start, topicLength: Int32(willTopic.utf8CodeUnitCount),
                    payload: willPayload.utf8Start, payloadLength: Int32(willPayload.utf8CodeUnitCount)
                )
                record("network:lastWillConfigured", lastWillConfigured)
                let connected = lastWillConfigured && client.connect(deadlineMS: 15_000)
                record("network:mqttConnect", connected)
                var subscribed = false
                var reconnected = false
                var rejectedOversize = false
                var published = false
                var received = false
                if connected {
                    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 129) { topic in
                        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 513) { payload in
                            let topicLength = axoloty_network_copy_topic(topic.baseAddress!, Int32(topic.count))
                            let payloadLength = axoloty_network_copy_payload(payload.baseAddress!, Int32(payload.count))
                            if topicLength > 0 && payloadLength >= 0 {
                                subscribed = client.subscribe(
                                    topic: topic.baseAddress!, topicLength: Int32(topicLength),
                                    deadlineMS: 10_000
                                )
                                reconnected = subscribed && client.waitForReconnect(deadlineMS: 20_000)
                                rejectedOversize = reconnected && !client.publish(
                                    topic: topic.baseAddress!, topicLength: 129,
                                    payload: payload.baseAddress!, payloadLength: 0
                                )
                                published = reconnected && client.publish(
                                    topic: topic.baseAddress!, topicLength: Int32(topicLength),
                                    payload: payload.baseAddress!, payloadLength: Int32(payloadLength)
                                )
                                received = published && client.waitForLoopback(deadlineMS: 10_000)
                            }
                        }
                    }
                }
                record("network:subscribe", subscribed)
                record("network:reconnect", reconnected)
                record("network:rejectOversize", rejectedOversize)
                record("network:publish", published)
                record("network:receive", received)
                let disconnected = client.disconnect()
                let cleanedUp = axoloty_network_cleanup() != 0
                record("network:disconnect", disconnected && cleanedUp)
            } else {
                record("network:mqttConnect", false)
                record("network:lastWillConfigured", false)
                record("network:subscribe", false)
                record("network:reconnect", false)
                record("network:rejectOutOfOrder", false)
                record("network:rejectOversize", false)
                record("network:publish", false)
                record("network:receive", false)
                record("network:disconnect", axoloty_network_cleanup() != 0)
            }
        } else {
            emittingExchangeEvidence = true
            let exchangeBits = axoloty_agent_test(90_000)
            let exchangeChecks: [(StaticString, UInt32)] = networkScenario == 1 ? [
                ("exchange:wifi", 1), ("exchange:ip", 2),
                ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
                ("exchange:reconnect", 512), ("exchange:advertise", 16),
                ("exchange:deadvertise", 128), ("exchange:disconnect", 256),
            ] : networkScenario == 2 ? [
                ("exchange:wifi", 1), ("exchange:ip", 2),
                ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
                ("exchange:reconnect", 512), ("exchange:brokerReconnect", 1024),
                ("exchange:advertise", 16), ("exchange:discover", 32),
                ("exchange:resolve", 64), ("exchange:deadvertise", 128),
                ("exchange:disconnect", 256),
            ] : [
                ("exchange:wifi", 1), ("exchange:ip", 2),
                ("exchange:mqttConnect", 4), ("exchange:subscribe", 8),
                ("exchange:reconnect", 512),
                ("exchange:advertise", 16), ("exchange:discover", 32),
                ("exchange:resolve", 64), ("exchange:deadvertise", 128),
                ("exchange:disconnect", 256),
            ]
            for (name, bit) in exchangeChecks { record(name, (exchangeBits & bit) != 0) }
        }
    }

    // Prove that a warmed corpus pass performs no heap allocation. The second
    // pass suppresses serial output so the trace covers only AxolotyWire work.
    var hotPathAllocations = UInt32.max
    if axoloty_heap_trace_begin() != 0 {
        runGeneratedCorpus { _, _ in }
        hotPathAllocations = axoloty_heap_trace_end()
    }
    let benchmarkMetrics = benchmarkGeneratedCorpus()

    // === Summary and completion ===

    let summaryStatus: StaticString = failed == 0 ? "completed" : "failed"
    rollingChecksum = nextChecksum("summary", "summary", "summary", summaryStatus,
                                   rollingChecksum, sequence, passed, failed)
    printPrefix("summary", "summary", "summary", summaryStatus, rollingChecksum)
    axoloty_print(",\"counts\":{\"passed\":")
    axoloty_print_uint("", passed)
    axoloty_print(",\"failed\":")
    axoloty_print_uint("", failed)
    axoloty_print("}")
    if failed != 0 {
        axoloty_print(",\"diagnostic\":\"one or more execution checks failed\"")
    }
    axoloty_print("}\n")
    sequence &+= 1

    let completionChecksum = nextChecksum("completion", "complete", "completion", summaryStatus,
                                          rollingChecksum, sequence, passed, failed)
    printPrefix("completion", "complete", "completion", summaryStatus, completionChecksum)
    axoloty_print(",\"counts\":{\"passed\":")
    axoloty_print_uint("", passed)
    axoloty_print(",\"failed\":")
    axoloty_print_uint("", failed)
    axoloty_print("},\"finalChecksum\":")
    axoloty_print_uint("", completionChecksum)
    if failed != 0 {
        axoloty_print(",\"diagnostic\":\"completion reflects failed execution checks\"")
    }
    axoloty_print(",\"metrics\":{\"freeInternalHeap\":")
    axoloty_print_uint("", axoloty_free_internal_heap())
    axoloty_print(",\"minimumFreeInternalHeap\":")
    axoloty_print_uint("", axoloty_min_free_internal_heap())
    axoloty_print(",\"largestInternalBlock\":")
    axoloty_print_uint("", axoloty_largest_internal_block())
    axoloty_print(",\"mainStackHighWater\":")
    axoloty_print_uint("", axoloty_main_stack_high_water())
    axoloty_print(",\"mainStackSize\":")
    axoloty_print_uint("", axoloty_main_stack_size())
    axoloty_print(",\"resetReason\":")
    axoloty_print_uint("", axoloty_reset_reason())
    axoloty_print(",\"hotPathAllocations\":")
    axoloty_print_uint("", hotPathAllocations)
    axoloty_print(",\"topicParseP50ns\":")
    axoloty_print_uint("", benchmarkMetrics.topicParseP50ns)
    axoloty_print(",\"topicParseP95ns\":")
    axoloty_print_uint("", benchmarkMetrics.topicParseP95ns)
    axoloty_print(",\"dtoDecodeP50ns\":")
    axoloty_print_uint("", benchmarkMetrics.dtoDecodeP50ns)
    axoloty_print(",\"dtoDecodeP95ns\":")
    axoloty_print_uint("", benchmarkMetrics.dtoDecodeP95ns)
    axoloty_print(",\"dtoEncodeP50ns\":")
    axoloty_print_uint("", benchmarkMetrics.dtoEncodeP50ns)
    axoloty_print(",\"dtoEncodeP95ns\":")
    axoloty_print_uint("", benchmarkMetrics.dtoEncodeP95ns)
    axoloty_print(",\"combinedP50ns\":")
    axoloty_print_uint("", benchmarkMetrics.combinedP50ns)
    axoloty_print(",\"combinedP95ns\":")
    axoloty_print_uint("", benchmarkMetrics.combinedP95ns)
    axoloty_print(",\"borrowedP50ns\":")
    axoloty_print_uint("", benchmarkMetrics.borrowedP50ns)
    axoloty_print(",\"borrowedP95ns\":")
    axoloty_print_uint("", benchmarkMetrics.borrowedP95ns)
    axoloty_print("}")
    axoloty_print("}\n")

    vTaskDelay(1000)
    esp_restart()
}
