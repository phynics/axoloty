// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time bounds for portable protocol state and endpoint storage.
///
/// These values are deliberately separate from ``WireBufferConfig``: wire
/// syntax limits belong to ``AxolotyWire``, while subscriber, family, and
/// endpoint capacities are protocol-state policy owned by this package.
public enum ProtocolBufferConfig {
    /// Maximum concurrent subscribers per event type.
    public static let maxSubscribers: Int = 8

    /// Maximum keyed entries in a bounded protocol family.
    public static let maxFamilyEntries: Int = 16

    /// Maximum subscribers per keyed family entry.
    public static let maxFamilySubscribers: Int = 4
}
