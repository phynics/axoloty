// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time bounds for portable protocol state and endpoint storage.
///
/// These values are deliberately separate from ``WireBufferConfig``: wire
/// syntax limits belong to ``AxolotyWire``, while subscriber, family, and
/// endpoint capacities are protocol-state policy owned by this package.
@usableFromInline
internal typealias ProtocolRouteStorage = InlineArray<256, UInt8>

@usableFromInline
internal typealias ProtocolRetainedRouteStorage = InlineArray<2_048, UInt8>

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

    /// Maximum association-route bytes retained by processor state.
    public static let maxRouteBytes: Int = ProtocolRouteStorage.count

    /// Maximum unique route bytes retained by one static action batch.
    public static let maxRetainedRouteBytes: Int = ProtocolRetainedRouteStorage.count
}
