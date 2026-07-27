// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Embedded Swift smoke entry point for ESP32-C6 (issue #321).
//
// Prints the AXOLOTY_SMOKE_OK marker, exercises AxolotyWire to prove the
// real Swift codec runs on-device, then restarts. The smoke harness
// captures the marker over serial.
//
// Uses axoloty_print (a C wrapper around esp_rom_printf) and StaticString
// instead of print() and String to avoid pulling in Swift's Unicode
// normalization runtime, which is not linked in the current Embedded Swift
// configuration.
//
// All AxolotyWire source files are compiled into the same module as this
// file by idf_component_register_swift(), so no import statement is needed.

@_cdecl("app_main")
func app_main() -> Int32 {
    axoloty_print("AXOLOTY_SMOKE_OK\n")

    // Exercise AxolotyWire: parse a Coaty topic and check the event type.
    // This proves the actual Swift wire codec — not a C port — runs on-device.
    let topic: StaticString = "coaty/3/ns/ADV/source-id"
    let topicView = TopicView(
        topicBytes: topic.utf8Start,
        length: topic.utf8CodeUnitCount
    )
    if topicView.eventType == .advertise {
        axoloty_print("AXOLOTY_WIRE_OK: topic parsed, eventType=advertise\n")
    } else {
        axoloty_print("AXOLOTY_WIRE_FAIL: topic parse failed\n")
    }

    // Exercise WireReader: decode a UUID from a JSON payload.
    let payload: StaticString = #"{"objectId":"33333333-3333-4333-8333-333333333333"}"#
    let reader = WireReader(
        bytes: payload.utf8Start,
        length: payload.utf8CodeUnitCount
    )
    if reader.readUUID("objectId") != nil {
        axoloty_print("AXOLOTY_WIRE_OK: UUID decoded from payload\n")
    } else {
        axoloty_print("AXOLOTY_WIRE_FAIL: UUID decode failed\n")
    }

    vTaskDelay(1000)
    esp_restart()
    return 0
}
