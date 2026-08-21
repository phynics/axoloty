// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time limits for the Foundation-free wire syntax boundary.
///
/// All sizes are compile-time constants so an embedded target can tune
/// them for its memory budget. Protocol-state capacities are intentionally
/// kept outside this wire-only configuration.
public enum WireBufferConfig {
    /// Maximum topic string length (bytes).
    public static let maxTopicLength: Int = 128

    /// Maximum payload size (bytes) for a single MQTT PUBLISH.
    public static let maxPayloadSize: Int = 512

    /// Maximum top-level fields retained by the borrowed JSON index.
    public static let maxIndexedFields: Int = 24

    /// Maximum topic levels in a Coaty topic (protocol, version, namespace,
    /// event, sourceId, correlationId, postfix = 7).
    public static let maxTopicLevels: Int = 7

}
