// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time configuration for the embedded wire routing path.
///
/// All sizes are compile-time constants so an embedded target can tune
/// them for its memory budget. The host runtime uses dynamic limits
/// (Broadcast actors with dictionaries); the embedded path uses these
/// static maximums and rejects overflow with a structured error.
public enum WireBufferConfig {
    /// Maximum topic string length (bytes).
    public static let maxTopicLength: Int = 128

    /// Maximum payload size (bytes) for a single MQTT PUBLISH.
    public static let maxPayloadSize: Int = 512

    /// Maximum topic levels in a Coaty topic (protocol, version, namespace,
    /// event, sourceId, correlationId, postfix = 7).
    public static let maxTopicLevels: Int = 7

    /// Maximum concurrent subscribers per event type.
    public static let maxSubscribers: Int = 8

    /// Maximum keyed entries in a BroadcastFamily (e.g. Advertise by filter,
    /// Channel by channel ID).
    public static let maxFamilyEntries: Int = 16

    /// Maximum subscribers per family entry.
    public static let maxFamilySubscribers: Int = 4
}
