// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time bounds for portable protocol state and endpoint storage.
///
/// These values are deliberately separate from ``WireBufferConfig``: wire
/// syntax limits belong to ``AxolotyWire``, while subscriber, family, and
/// endpoint capacities are protocol-state policy owned by this package.
public enum ProtocolBufferConfig {
    /// Accepted capacity presets selected from G1 measurements.
    public enum Preset {
        /// Smallest exhaustion and rollback test point.
        public static let tiny: Int = 1
        /// Fixed ESP32-C6 static firmware profile.
        public static let esp32C6Static: Int = 16
        /// Reusable host-side default profile.
        public static let hostDefault: Int = 64
    }

    /// Maximum association route bytes retained by protocol state.
    public static let maxTopicLength: Int = 128

    /// Maximum concurrent subscribers per event type.
    public static let maxSubscribers: Int = 8

    /// Maximum keyed entries in a bounded protocol family.
    public static let maxFamilyEntries: Int = 16

    /// Maximum subscribers per keyed family entry.
    public static let maxFamilySubscribers: Int = 4
}
