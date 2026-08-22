// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

/// Protocol-owned adaptation of a Coaty `objectFilter` wire value.
///
/// The adapter owns only the bounded predicate program. JSON tokenization and
/// semantic evaluation remain in ``AxolotyObjectModel``; this type supplies
/// the protocol boundary and the query-event optional-filter policy. An absent
/// query filter creates an empty predicate, which matches every object as
/// required by the Coaty filter contract.
public struct CoatyFilterAdapter<let nodeCapacity: Int, let pathCapacity: Int, let literalCapacity: Int, let arenaCapacity: Int>: ~Copyable {
    private let predicate: ObjectPredicate<nodeCapacity, pathCapacity, literalCapacity, arenaCapacity>

    /// Creates an adapter with no filter, matching every object.
    public init() {
        predicate = ObjectPredicate()
    }

    /// Decodes and owns one raw Coaty `objectFilter` value.
    ///
    /// - Parameter objectFilter: A borrowed complete JSON filter value. The
    ///   adapter copies all predicate paths and operands before returning.
    /// - Throws: ``ProtocolError`` with ``ProtocolError/Code/malformedPayload``
    ///   when the filter is not a valid bounded Coaty predicate.
    public init(decoding objectFilter: ByteSlice) throws(ProtocolError) {
        do throws(ObjectError) {
            predicate = try ObjectPredicate(decoding: objectFilter)
        } catch {
            throw ProtocolError(.malformedPayload, detail: UInt16(error.reason.rawValue))
        }
    }

    /// Creates an adapter from a decoded query event.
    ///
    /// A query without `objectFilter` is the protocol's match-all form.
    /// The query DTO retains only a borrowed view, while this adapter owns its
    /// decoded predicate and therefore does not retain the query buffer.
    public init(query: borrowing QueryWireData) throws(ProtocolError) {
        guard let objectFilter = query.objectFilter else {
            self.init()
            return
        }
        try self.init(decoding: objectFilter)
    }

    /// Tests a bounded dynamic object without copying its fields.
    public borrowing func matches<let byteCapacity: Int, let fieldCapacity: Int>(
        object: borrowing BoundedDynamicObject<byteCapacity, fieldCapacity>
    ) -> Bool {
        predicate.matches(object: object)
    }
}
