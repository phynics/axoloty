// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Axoloty
import Testing

/// Downstream-style compile regression for issue #294.
///
/// This file deliberately imports ONLY `Axoloty` — no `@testable import
/// Axoloty`, no `import AxolotyWire`. It references wire symbols that were
/// public before the #290 extraction and are re-exported back onto the
/// `Axoloty` module by the compatibility shim in
/// `Source/Common/WireImportShim.swift`.
///
/// If that shim is removed, this file fails to compile — the wire symbols
/// become unresolvable through `import Axoloty` alone — which is exactly the
/// regression it guards against. The assertions exercise the import surface
/// only; they do not duplicate the codec behavior covered by `WireCodecTests`.
@Suite
struct AxolotyWireImportSurfaceTests {

    @Test
    func formerlyPublicWireSymbolsAreReachableThroughAxolotyImport() throws {
        // Value type + initializer + static member.
        let uuid = try #require(UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
        #expect(uuid != UUID16.zero)

        // Configuration enum with static compile-time limits.
        #expect(WireBufferConfig.maxTopicLength > 0)

        // Raw-value enum with a computed property and a public raw-value init.
        #expect(WireEventType.advertise.isOneWay)
        #expect(WireEventType(rawValue: "ASC") == .associate)

        // Wire DTO struct + codec protocols are visible through the shim.
        #expect(wireCodecConformance(AssociateWireData.self))
        #expect(wireEventSurface(BorrowedWireEvent.self, OwnedWireEvent.self))
    }
}

private func wireEventSurface(_ borrowed: BorrowedWireEvent.Type, _ owned: OwnedWireEvent.Type) -> Bool {
    borrowed == BorrowedWireEvent.self && owned == OwnedWireEvent.self
}

/// Proves the ``WireDecodable`` and ``WireEncodable`` protocols (and a
/// conforming DTO type) are visible through `import Axoloty` alone.
///
/// Generic conformance is resolved at compile time, so this function fails to
/// type-check unless both protocols and ``AssociateWireData`` are reachable
/// via the re-export shim.
private func wireCodecConformance<T: WireDecodable & WireEncodable>(_: T.Type) -> Bool {
    true
}
