// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import AxolotyObjectModel
import AxolotyWire

/// An application opt-in to Discover samples for one exact object identifier.
///
/// Constructing an interest performs no I/O. The application submits the
/// request, owns its collection window, and checks runtime continuity before
/// applying the matched evidence.
public struct ReconciliationInterest: Sendable {
    /// The requested object.
    public let objectID: ObjectID
    /// The finite Core request timeout in milliseconds.
    public let timeoutMS: UInt32

    /// Creates an exact-ID interest with a bounded timeout.
    ///
    /// - Parameters:
    ///   - objectID: The requested object.
    ///   - timeoutMS: A positive interval of at most `Int32.max` milliseconds.
    /// - Throws: ``ObjectViewError`` if the interval is outside that range.
    public init(objectID: ObjectID, timeoutMS: UInt32) throws(ObjectViewError) {
        guard (1...UInt32(Int32.max)).contains(timeoutMS) else {
            throw ObjectViewError(.invalidReconciliationTimeout)
        }
        self.objectID = objectID
        self.timeoutMS = timeoutMS
    }

    /// Prepares an exact-ID Discover without submitting it.
    ///
    /// - Parameters:
    ///   - correlationID: A fresh correlation for this attempt.
    ///   - profile: The attached runtime's wire profile.
    /// - Returns: A request for the application to submit.
    /// - Throws: ``WireEncodeError`` if the profile cannot encode the payload.
    public func request(correlationID: UUID16, profile: WireProfile) throws(WireEncodeError) -> RuntimeRequest {
        var id = [UInt8](repeating: 0, count: 36)
        try id.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) in
            guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
            var textWriter = WireCodec(profile: .coaty3JSON).writer(buffer: base, capacity: buffer.count)
            try textWriter.writeUUID(objectID.uuid)
        }
        var output = [UInt8](repeating: 0, count: 64)
        let length = try output.withUnsafeMutableBufferPointer { buffer throws(WireEncodeError) in
            guard let base = buffer.baseAddress else { throw WireEncodeError.bufferOverflow }
            var writer = WireCodec(profile: profile).writer(buffer: base, capacity: buffer.count)
            try writer.beginObject()
            try id.withUnsafeBufferPointer { text throws(WireEncodeError) in
                guard let base = text.baseAddress else { throw WireEncodeError.invalidValue }
                try writer.writeStringField("objectId", ByteSlice(bytes: base, length: text.count))
            }
            try writer.endObject()
            return writer.position
        }
        output.removeSubrange(length..<output.count)
        return .discover(correlationID: correlationID, payload: output, timeoutMS: timeoutMS)
    }

    /// Copies an exact-ID Resolve for this attempt.
    ///
    /// - Parameters:
    ///   - event: A normalized runtime event.
    ///   - correlationID: The correlation allocated to the current attempt.
    ///   - profile: The attached runtime's wire profile.
    ///   - revision: Optional revision supplied by the application.
    /// - Returns: Owned matching evidence, or `nil` for an unrelated event.
    /// - Throws: ``ObjectViewError`` if the matching event's object is malformed
    ///   or exceeds the per-object byte limit.
    public func observation(
        from event: RuntimeEventValue,
        correlationID: UUID16,
        profile: WireProfile,
        revision: ObjectRevision? = nil
    ) throws(ObjectViewError) -> ObjectObservation? {
        guard event.family == .resolve, event.context.provenance == .transport,
              event.context.correlationID == correlationID else { return nil }
        return try ObjectObservation.decode(
            event, delivery: .resolve, profile: profile, expected: objectID, revision: revision
        )
    }
}

extension ObjectObservation {
    /// Copies the object in a normalized Advertise event.
    ///
    /// - Parameters:
    ///   - event: An event from the attached runtime.
    ///   - profile: The attached runtime's wire profile.
    ///   - revision: Optional revision supplied by the application.
    /// - Returns: Owned evidence, or `nil` for another event family.
    /// - Throws: ``ObjectViewError`` if the event's object is malformed
    ///   or exceeds the per-object byte limit.
    public static func advertisement(
        from event: RuntimeEventValue,
        profile: WireProfile,
        revision: ObjectRevision? = nil
    ) throws(ObjectViewError) -> Self? {
        guard event.family == .advertise else { return nil }
        return try decode(event, delivery: .advertise, profile: profile, expected: nil, revision: revision)
    }

    fileprivate static func decode(
        _ event: RuntimeEventValue, delivery: ObjectDeliveryKind, profile: WireProfile,
        expected: ObjectID?, revision: ObjectRevision?
    ) throws(ObjectViewError) -> Self? {
        return try event.value.withUnsafeBufferPointer { buffer throws(ObjectViewError) in
            guard let base = buffer.baseAddress, buffer.count <= WireBufferConfig.maxPayloadSize else {
                throw ObjectViewError(.invalidEventPayload)
            }
            let codec = WireCodec(profile: profile)
            let reader = codec.reader(bytes: base, length: buffer.count)
            guard let bytes = reader.readField("object") else { throw ObjectViewError(.invalidEventPayload) }
            let id = bytes.withBytes { pointer, count in
                codec.reader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count).readUUID("objectId")
            }
            guard let id else { throw ObjectViewError(.invalidEventPayload) }
            if let expected, id != expected.uuid { return nil }
            guard bytes.length <= ObjectViewConfiguration.maximumObjectBytes else {
                throw ObjectViewError(.objectBytesExceedCapacity)
            }
            return ObjectObservation(
                objectID: ObjectID(uuid: id),
                source: ObjectSource(rawValue: event.context.sourceID),
                delivery: delivery,
                profile: profile,
                revision: revision,
                bytes: bytes.ownedBytes()
            )
        }
    }
}
