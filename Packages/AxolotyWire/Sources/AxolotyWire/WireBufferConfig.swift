// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Compile-time configuration for the embedded wire routing path.
///
/// All sizes are compile-time constants so an embedded target can tune
/// them for their memory budget. The embedded path uses these static maximums
/// and rejects overflow with a structured error.
@usableFromInline
internal typealias TopicLevelStorage = InlineArray<7, Int>

public enum WireBufferConfig {
    /// Maximum topic string length (bytes).
    public static let maxTopicLength: Int = 128

    /// Maximum payload size (bytes) for a single MQTT PUBLISH.
    public static let maxPayloadSize: Int = 2_048

    /// Maximum top-level fields retained by the borrowed JSON index.
    public static let maxIndexedFields: Int = 24

    /// Maximum topic levels in a Coaty topic (protocol, version, namespace,
    /// event, sourceId, correlationId, postfix = 7).
    public static let maxTopicLevels: Int = TopicLevelStorage.count

    /// Maximum concurrent subscribers per event type.
    public static let maxSubscribers: Int = 8

    /// Maximum keyed entries in a bounded family.
    public static let maxFamilyEntries: Int = 16

    /// Maximum subscribers per keyed family entry.
    public static let maxFamilySubscribers: Int = 4

}
