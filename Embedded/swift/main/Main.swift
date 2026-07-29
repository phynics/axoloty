// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Embedded Swift entry point for ESP32-C6 (issues #321, #322).
//
// Runs AxolotyWire test vectors on-device using the real Swift wire codec.
// Emits structured JSON Lines records over serial. The host harness parses
// these records and validates pass/fail counts.
//
// Success is NEVER emitted before all checks complete.

import AxolotyWire

@_cdecl("app_main")
func app_main() -> Int32 {
    axoloty_print("{\"phase\":\"boot\",\"status\":\"started\"}\n")

    var passed: UInt32 = 0
    var failed: UInt32 = 0

    @inline(__always)
    func printStatic(_ value: StaticString) {
        axoloty_print(
            UnsafeRawPointer(value.utf8Start).assumingMemoryBound(to: CChar.self)
        )
    }

    @inline(__always)
    func record(_ name: StaticString, _ ok: Bool) {
        if ok {
            passed &+= 1
            axoloty_print("{\"test\":\"")
            printStatic(name)
            axoloty_print("\",\"status\":\"passed\"}\n")
        } else {
            failed &+= 1
            axoloty_print("{\"test\":\"")
            printStatic(name)
            axoloty_print("\",\"status\":\"failed\"}\n")
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
    record("config:maxSubscribers8", WireBufferConfig.maxSubscribers == 8)
    record("config:maxFamilyEntries16", WireBufferConfig.maxFamilyEntries == 16)

    // === Summary ===

    axoloty_print_uint("{\"tests\":{\"passed\":", passed)
    axoloty_print_uint(",\"failed\":", failed)
    axoloty_print("}}\n")

    if failed == 0 {
        axoloty_print("{\"phase\":\"smoke\",\"status\":\"completed\"}\n")
    } else {
        axoloty_print("{\"phase\":\"smoke\",\"status\":\"failed\"}\n")
    }

    vTaskDelay(1000)
    esp_restart()
    return 0
}
