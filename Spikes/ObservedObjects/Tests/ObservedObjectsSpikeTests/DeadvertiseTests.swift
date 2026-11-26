// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyObservedObjects
import AxolotyWire
import Testing

@Suite
struct DeadvertiseTests {
    @Test(arguments: WireProfile.allCases)
    func mixedWithdrawalsPreserveEvidenceAndRejectMalformedArrays(profile: WireProfile) throws {
        let pump = HostTraceFixture.pump.uuid
        let other = HostTraceFixture.otherPump.uuid
        let policy = try ObjectViewConfiguration(staleAfterTicks: 10, retainForTicks: 20)
        var view = try ObjectView(watching: [ObjectID(uuid: pump), ObjectID(uuid: other)], configuration: policy, profile: profile)
        let session = view.beginSession()
        let reporter = HostTraceFixture.responder.uuid
        let context = RuntimeEventContext(sourceID: reporter, namespace: HostTraceFixture.namespace, receiptTimeMS: 99)
        let malformed = RuntimeEventValue(
            family: .deadvertise, context: context,
            value: try payload(profile: profile, malformed: true)
        )
        #expect(throws: ObjectViewError(.invalidEventPayload)) {
            try view.noteDeadvertise(malformed, in: session)
        }
        #expect(view.snapshot(for: ObjectID(uuid: pump), at: 99).uncertainty.isEmpty)
        let withdrawal = RuntimeEventValue(
            family: .deadvertise, context: context,
            value: try payload(profile: profile, malformed: false)
        )
        let count = try view.noteDeadvertise(withdrawal, in: session)
        #expect(count == 2)

        let advertisement = RuntimeEventValue(
            family: .advertise, context: context,
            value: try HostTraceWire.advertisePayload(profile: profile)
        )
        let bytes = try #require(HostTraceWire.objectBytes(in: advertisement, profile: profile))
        let observation = ObjectObservation(
            objectID: ObjectID(uuid: pump), source: ObjectSource(rawValue: reporter),
            delivery: .advertise, profile: profile, revision: nil, bytes: bytes
        )
        try view.apply(observation, in: session, observedAt: 100)
        let ambiguous = view.snapshot(for: ObjectID(uuid: pump), at: 101)
        #expect(ambiguous.uncertainty.contains(.withdrawalObserved))
        guard case .observed(let candidate) = ambiguous.evidence else {
            Issue.record("withdrawal lost the retained advertisement")
            return
        }
        #expect(candidate.bytes == bytes)
        #expect(view.snapshot(for: ObjectID(uuid: other), at: 101).uncertainty.contains(.withdrawalObserved))
    }

    private func payload(profile: WireProfile, malformed: Bool) throws(WireEncodeError) -> [UInt8] {
        let pump = HostTraceFixture.pump.uuid
        let other = HostTraceFixture.otherPump.hyphenated
        if profile == .coaty3JSON {
            let tail = malformed ? "false" : "\"\(other)\""
            return Array("{\"objectIds\":[\"\(HostTraceFixture.pump.hyphenated)\",\"opaque\",\(tail)]}".utf8)
        }
        var output = [UInt8](repeating: 0, count: 128)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) in
            guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
            var writer = CBORWriter(buffer: base, capacity: buffer.count)
            try writer.writeMapHeader(1)
            try writeText("objectIds", to: &writer)
            try writer.writeArrayHeader(3)
            try writer.writeUUID(pump)
            try writeText("opaque", to: &writer)
            if malformed {
                try writer.writeBool(false)
            } else {
                try writeText(other, to: &writer)
            }
            return writer.position
        }
        return Array(output.prefix(length))
    }

    private func writeText(_ text: String, to writer: inout CBORWriter) throws(WireEncodeError) {
        try Array(text.utf8).withUnsafeBufferPointer { buffer throws(WireEncodeError) in
            guard let base = buffer.baseAddress else { throw WireEncodeError.invalidValue }
            try writer.writeTextString(ByteSlice(bytes: base, length: buffer.count))
        }
    }
}
