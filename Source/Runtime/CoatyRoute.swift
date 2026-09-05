// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@_spi(AxolotyRuntimeAdapter) import AxolotyProtocol
import AxolotyWire

/// Builds the Coaty Core Profile 3 routes the runtime publishes on.
///
/// Route synthesis is profile logic, not transport logic: the layout is
/// defined by `coaty/3`, not by any carrier. It lived in the MQTT binding by
/// accident of history, which meant a second transport would have had to
/// reimplement it. The runtime now hands adapters a finished route, and an
/// adapter decides only how to put bytes on a wire.
///
/// The static profile still synthesizes its own routes; unifying the two is
/// tracked separately, because that code is compiled for Embedded Swift.
public enum CoatyRoute {
    /// Builds the exact Coaty route for a publication routing key.
    ///
    /// The destination buffer is sized from a hand-rolled byte-budget
    /// (namespace length, filter length, and the fixed prefix/UUID widths);
    /// the returned string is truncated to the bytes ``TopicBuilder``
    /// actually wrote, never to the (possibly over-estimated) allocation, so
    /// an overestimate can never leak trailing NUL bytes onto the wire.
    ///
    /// - Parameters:
    ///   - key: The routing key supplying the event type, source, and
    ///     optional correlation ID.
    ///   - namespace: The runtime namespace level.
    ///   - eventTypeFilter: An optional event-type filter suffix.
    ///   - eventTypeFilterKind: The separator required by the filter's wire
    ///     meaning.
    /// - Throws: ``AxolotyError/runtime(code:reason:)`` with
    ///   ``AxolotyError/RuntimeErrorCode/capacityExceeded`` if the computed
    ///   buffer budget is smaller than what the topic actually requires.
    public static func route(
        for key: ProtocolRoutingKey,
        namespace: String,
        eventTypeFilter: [UInt8]? = nil,
        eventTypeFilterKind: ProtocolEventTypeFilterKind = .direct
    ) throws -> String {
        let namespaceBytes = Array(namespace.utf8)
        let namespaceStorage = namespaceBytes.isEmpty ? [UInt8(0)] : namespaceBytes
        let filterBytes = eventTypeFilter ?? []
        let filterStorage = filterBytes.isEmpty ? [UInt8(0)] : filterBytes
        let filterLength = eventTypeFilter.map { $0.count + (eventTypeFilterKind == .objectType ? 2 : 1) } ?? 0
        let capacity = 8 + namespaceBytes.count + 1 + 3 + filterLength + 1 + 36 + (key.correlationID == nil ? 0 : 37)
        var bytes = [UInt8](repeating: 0, count: capacity)
        let writtenLength: Int = try bytes.withUnsafeMutableBufferPointer { output in
            try namespaceStorage.withUnsafeBufferPointer { namespace in
                try filterStorage.withUnsafeBufferPointer { filter in
                    var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
                    let namespaceSlice = ByteSlice(bytes: namespace.baseAddress!, length: namespaceBytes.count)
                    do {
                        try builder.writePrefix()
                        try builder.writeNamespace(namespaceSlice)
                        let filterSlice = eventTypeFilter == nil
                            ? nil
                            : ByteSlice(bytes: filter.baseAddress!, length: filterBytes.count)
                        try builder.writeEventType(
                            key.capability.wireEventType,
                            filter: filterSlice,
                            filterKind: eventTypeFilterKind == .objectType ? .objectType : .direct
                        )
                        try builder.writeSourceId(key.sourceID)
                        if let correlationID = key.correlationID {
                            try builder.writeCorrelationId(correlationID)
                        }
                    } catch {
                        throw AxolotyError.runtime(
                            code: .capacityExceeded,
                            reason: "Coaty route storage capacity calculation is invalid"
                        )
                    }
                    return builder.position
                }
            }
        }
        return String(decoding: bytes[0..<writtenLength], as: UTF8.self)
    }

    public static func uuidString(_ value: UUID16) -> String {
        var bytes = [UInt8](repeating: 0, count: 36)
        bytes.withUnsafeMutableBufferPointer { output in
            var builder = TopicBuilder(buffer: output.baseAddress!, capacity: output.count)
            guard (try? builder.writeSourceId(value)) != nil else {
                preconditionFailure("UUID storage capacity calculation is invalid")
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
