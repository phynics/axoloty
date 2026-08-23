// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire

/// Binding-owned classification for an association route.
public enum ProtocolRouteClassification: UInt8, Sendable, Equatable {
    /// A route owned by the Coaty binding.
    case coaty = 0
    /// A typed route owned by the binding's external adapter.
    case external = 1
    /// A route that is unrelated to this protocol profile.
    case unrelated = 2
}

/// Classifies association routes without imposing a global route grammar.
public protocol ProtocolRouteClassifier {
    /// Classifies a borrowed route synchronously.
    ///
    /// The classifier is supplied by the binding. This protocol deliberately
    /// does not define a global MQTT route grammar.
    func classify(_ route: ByteSlice) -> ProtocolRouteClassification
}

/// A small exact-match classifier useful for a binding-owned route table.
public struct ExactProtocolRouteClassifier: ProtocolRouteClassifier, Sendable {
    private let externalRoute: InlineArray<128, UInt8>
    private let externalLength: Int

    /// Creates a classifier from a fixed route literal.
    ///
    /// - Parameter externalRoute: Binding-owned route to classify as external.
    public init(externalRoute: StaticString) {
        let bytes = externalRoute.utf8Start
        let length = externalRoute.utf8CodeUnitCount
        var fixed = InlineArray<128, UInt8>(repeating: 0)
        for index in 0..<min(length, 128) {
            let byte = bytes[index]
            fixed[index] = byte
        }
        self.externalRoute = fixed
        self.externalLength = length
    }

    /// Classifies the configured external route, treating other non-empty
    /// routes as Coaty and empty routes as unrelated.
    public func classify(_ route: ByteSlice) -> ProtocolRouteClassification {
        guard route.length == externalLength, route.length <= 128 else { return .coaty }
        for index in 0..<route.length {
            guard route.byte(at: index) == externalRoute[index] else { return .coaty }
        }
        return .external
    }
}
