// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Zero-allocation parsing of a Coaty MQTT topic string.
///
/// Scans the topic bytes in place, returning topic levels as `ByteSlice`
/// without `String.components(separatedBy:)` array allocation. Topic levels
/// are returned as `ByteSlice` — no String or Array is allocated.
///
/// The Coaty topic structure is:
/// `coaty/<version>/<namespace>/<eventType>[filter]/<sourceId>[/<correlationId>]`
///
/// - Important: When constructed from ``BorrowedMessage``, use this view and
///   its returned ``ByteSlice`` levels only in the message's synchronous
///   borrow scope. Copy data before an `await` or another isolation-domain hop.
public struct TopicView {
    /// The raw pointer to the topic byte buffer.
    @usableFromInline let bytes: UnsafeRawPointer
    /// The number of valid bytes pointed to by ``bytes``.
    @usableFromInline let byteCount: Int

    /// Up to 7 levels: protocol, version, namespace, event, sourceId,
    /// optional correlationId, optional postfix.
    public var levelCount: Int {
        _levelCount
    }

    /// The complete borrowed topic buffer.
    ///
    /// The slice is valid only while the source topic buffer remains pinned.
    public var rawBytes: ByteSlice {
        ByteSlice(pointer: bytes, length: byteCount)
    }
    private var _levelCount: Int

    /// Start offsets of up to 7 parsed topic levels within ``bytes``.
    @usableFromInline internal var levelOffsets: TopicLevelStorage
    /// Lengths of up to 7 parsed topic levels within ``bytes``.
    @usableFromInline internal var levelLengths: TopicLevelStorage

    /// Creates a topic view by parsing the given topic bytes in place.
    ///
    /// The view holds the pointer without copying; the caller must ensure the
    /// buffer remains valid for the view's lifetime.
    ///
    /// - Parameters:
    ///   - topicBytes: A pointer to the UTF-8 topic bytes.
    ///   - length: The number of valid bytes at `topicBytes`.
    public init(topicBytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(topicBytes)
        self.byteCount = max(0, length)
        self.levelOffsets = InlineArray(repeating: 0)
        self.levelLengths = InlineArray(repeating: 0)
        self._levelCount = 0
        parseLevels()
    }

    private mutating func parseLevels() {
        var start = 0
        var count = 0
        for i in 0..<byteCount where bytes.load(fromByteOffset: i, as: UInt8.self) == 0x2F {
            if count < WireBufferConfig.maxTopicLevels {
                levelOffsets[count] = start
                levelLengths[count] = i - start
            }
            count += 1
            start = i + 1
        }
        // Last non-empty segment after the final '/'. A trailing slash keeps
        // the historical behavior of not retaining an empty level.
        if start < byteCount && count < WireBufferConfig.maxTopicLevels {
            levelOffsets[count] = start
            levelLengths[count] = byteCount - start
            count += 1
        } else if start < byteCount {
            // Preserve the overflow in `_levelCount` so validation rejects
            // the topic instead of silently truncating its stored levels.
            count += 1
        }
        _levelCount = count
    }

    /// Returns the bytes of the topic level at the given index, or nil.
    public func level(_ index: Int) -> ByteSlice? {
        guard index >= 0,
              index < _levelCount,
              index < WireBufferConfig.maxTopicLevels else { return nil }
        let offset = levelOffsets[index]
        let length = levelLengths[index]
        return ByteSlice(pointer: bytes.advanced(by: offset), length: length)
    }

    /// The event type parsed from level 3, or nil if unrecognized.
    ///
    /// Handles event levels with optional filters (e.g. `ADV:sensors`). The
    /// event code must be *exactly* three bytes: the full event level with no
    /// filter, or the three bytes preceding `:` when a filter is present.
    /// Over-long codes that merely share a three-byte prefix with a recognized
    /// code (e.g. `ADVZ`) are rejected rather than coarse-prefix-matched.
    public var eventType: WireEventType? {
        guard let eventLevel = level(3) else { return nil }
        guard let colon = eventLevel.findByteIndex(0x3A) else { // ':'
            // No filter: the entire level must be exactly a recognized code.
            guard eventLevel.length == 3 else { return nil }
            return WireEventType(wireCode: eventLevel)
        }
        // Filter present: the code is exactly the three bytes before ':'.
        guard colon == 3 else { return nil }
        return WireEventType(wireCode: eventLevel.subSlice(from: 0, length: 3))
    }

    /// The event-type filter (the part after ':' in level 3), if present.
    public var eventTypeFilter: ByteSlice? {
        guard let eventLevel = level(3) else { return nil }
        return eventLevel.findByte(0x3A) // ':'
    }

    /// The namespace level (topic level 2), or nil if absent.
    public var namespaceLevel: ByteSlice? {
        level(2)
    }

    /// The source identifier level (topic level 4), or nil if absent.
    public var sourceIdLevel: ByteSlice? {
        level(4)
    }

    /// The correlation identifier level (topic level 5), or nil if absent.
    public var correlationIdLevel: ByteSlice? {
        level(5)
    }

    /// Whether this topic is a raw (non-Coaty) topic.
    public var isRawTopic: Bool {
        guard let proto = level(0) else { return true }
        return !proto.equals("coaty")
    }

    /// Access the raw topic bytes.
    public func withBytes<R>(_ body: (UnsafeRawPointer, Int) -> R) -> R {
        body(bytes, byteCount)
    }

    /// Strictly validates the Coaty topic layout and event code.
    ///
    /// Enforces the exact wire contract
    /// `coaty/3/<namespace>/<eventType>[:<filter>]/<sourceId>[/<correlationId>]`:
    ///
    /// * level 0 is exactly `coaty`
    /// * level 1 is exactly the protocol version `3`
    /// * the namespace level is non-empty
    /// * the event level is exactly a recognized three-byte code with an
    ///   optional filter
    /// * the source-id level is a valid hyphenated UUID
    /// * two-way event types carry exactly one additional correlation-id
    ///   level, while one-way event types carry none
    /// * no extra (postfix) levels are present
    ///
    /// This rejects over-long or over-short event levels, near-match event
    /// codes, extra path segments, and malformed IDs that ``eventType`` and
    /// the slicing accessors otherwise tolerate. Any topic that fails here
    /// must not be routed.
    ///
    /// - Parameter maximumTopicLength: Maximum accepted topic length for this
    ///   binding. The Embedded wire uses ``WireBufferConfig.maxTopicLength``;
    ///   a host runtime may select a larger bounded budget for generated
    ///   profile topics.
    /// - Throws: ``WireDecodeError`` with reason ``WireDecodeError/Reason/malformedTopic``
    ///   when the layout or event code is not the exact Coaty form.
    public func validate(
        maximumTopicLength: Int = WireBufferConfig.maxTopicLength
    ) throws(WireDecodeError) {
        guard maximumTopicLength >= 0, byteCount <= maximumTopicLength else {
            throw WireDecodeError(.malformedTopic)
        }
        guard levelCount >= 4 else { throw WireDecodeError(.malformedTopic) }
        guard let proto = level(0), proto.equals("coaty") else {
            throw WireDecodeError(.malformedTopic)
        }
        guard let version = level(1), version.equals("3") else {
            throw WireDecodeError(.malformedTopic)
        }
        guard let namespace = level(2), namespace.length > 0 else {
            throw WireDecodeError(.malformedTopic)
        }
        guard let eventType = self.eventType else {
            throw WireDecodeError(.malformedTopic)
        }
        guard let sourceId = level(4), UUID16(parsing: sourceId) != nil else {
            throw WireDecodeError(.malformedTopic)
        }

        let hasCorrelation = levelCount >= 6
        if eventType.isOneWay {
            // One-way events carry exactly 5 levels and never a correlation ID.
            guard levelCount == 5 else { throw WireDecodeError(.malformedTopic) }
        } else {
            // Two-way events carry exactly 6 levels with a non-empty correlation.
            guard levelCount == 6 else { throw WireDecodeError(.malformedTopic) }
            guard hasCorrelation,
                  let correlation = level(5),
                  correlation.length > 0 else {
                throw WireDecodeError(.malformedTopic)
            }
        }
    }
}

/// Foundation-free event type enum for Coaty communication events.
///
/// Each case has a three-letter wire code (e.g. `ADV` for `advertise`) carried
/// on the event-type level of a Coaty MQTT topic. The wire code is exposed via
/// ``wireCode`` as a `StaticString` for byte-level comparison without String
/// allocation. Host callers can use ``rawValue`` via the
/// `RawRepresentable<String>` bridge available in non-Embedded builds.
public enum WireEventType: Sendable {
    /// Advertise event (`ADV`).
    case advertise
    /// Deadvertise event (`DAD`).
    case deadvertise
    /// Channel event (`CHN`).
    case channel
    /// Associate event (`ASC`).
    case associate
    /// IoValue event (`IOV`).
    case ioValue
    /// Discover event (`DSC`).
    case discover
    /// Resolve event (`RSV`).
    case resolve
    /// Query event (`QRY`).
    case query
    /// Retrieve event (`RTV`).
    case retrieve
    /// Update event (`UPD`).
    case update
    /// Complete event (`CPL`).
    case complete
    /// Call event (`CLL`).
    case call
    /// Return event (`RTN`).
    case returnEvent

    /// The three-letter wire code as a `StaticString` (e.g. `"ADV"`).
    ///
    /// Use this property for byte-level comparison without String allocation.
    /// In Embedded Swift, this is the canonical wire-code accessor.
    public var wireCode: StaticString {
        switch self {
        case .advertise: return "ADV"
        case .deadvertise: return "DAD"
        case .channel: return "CHN"
        case .associate: return "ASC"
        case .ioValue: return "IOV"
        case .discover: return "DSC"
        case .resolve: return "RSV"
        case .query: return "QRY"
        case .retrieve: return "RTV"
        case .update: return "UPD"
        case .complete: return "CPL"
        case .call: return "CLL"
        case .returnEvent: return "RTN"
        }
    }

    /// Parses a wire code from a `ByteSlice` (e.g. the first 3 bytes of an
    /// event-type topic level).
    ///
    /// Returns nil if the slice does not match any known wire code.
    public init?(wireCode slice: ByteSlice) {
        guard let eventType = Self.parseWireCode(slice) else { return nil }
        self = eventType
    }

    /// Returns `true` for fire-and-forget event types that carry no
    /// correlation ID (advertise, deadvertise, channel, associate, ioValue).
    public var isOneWay: Bool {
        switch self {
        case .advertise, .deadvertise, .channel, .associate, .ioValue:
            return true
        default:
            return false
        }
    }

    private static func parseWireCode(_ slice: ByteSlice) -> WireEventType? {
        guard slice.length == 3, let first = slice.byte(at: 0) else { return nil }
        switch first {
        case 0x41: return parseA(slice)
        case 0x43: return parseC(slice)
        case 0x44: return parseD(slice)
        case 0x49: return slice.equals("IOV") ? .ioValue : nil
        case 0x51: return slice.equals("QRY") ? .query : nil
        case 0x52: return parseR(slice)
        case 0x55: return slice.equals("UPD") ? .update : nil
        default: return nil
        }
    }

    private static func parseA(_ slice: ByteSlice) -> WireEventType? {
        if slice.equals("ADV") { return .advertise }
        if slice.equals("ASC") { return .associate }
        return nil
    }

    private static func parseC(_ slice: ByteSlice) -> WireEventType? {
        if slice.equals("CHN") { return .channel }
        if slice.equals("CPL") { return .complete }
        if slice.equals("CLL") { return .call }
        return nil
    }

    private static func parseD(_ slice: ByteSlice) -> WireEventType? {
        if slice.equals("DAD") { return .deadvertise }
        if slice.equals("DSC") { return .discover }
        return nil
    }

    private static func parseR(_ slice: ByteSlice) -> WireEventType? {
        if slice.equals("RSV") { return .resolve }
        if slice.equals("RTV") { return .retrieve }
        if slice.equals("RTN") { return .returnEvent }
        return nil
    }

    private static func parseRawValue(_ rawValue: String) -> WireEventType? {
        guard rawValue.utf8.count == 3, let first = rawValue.utf8.first else { return nil }
        switch first {
        case 0x41: return parseRawA(rawValue)
        case 0x43: return parseRawC(rawValue)
        case 0x44: return parseRawD(rawValue)
        case 0x49: return rawValue == "IOV" ? .ioValue : nil
        case 0x51: return rawValue == "QRY" ? .query : nil
        case 0x52: return parseRawR(rawValue)
        case 0x55: return rawValue == "UPD" ? .update : nil
        default:
            return nil
        }
    }

    private static func parseRawA(_ value: String) -> WireEventType? {
        if value == "ADV" { return .advertise }
        if value == "ASC" { return .associate }
        return nil
    }

    private static func parseRawC(_ value: String) -> WireEventType? {
        if value == "CHN" { return .channel }
        if value == "CPL" { return .complete }
        if value == "CLL" { return .call }
        return nil
    }

    private static func parseRawD(_ value: String) -> WireEventType? {
        if value == "DAD" { return .deadvertise }
        if value == "DSC" { return .discover }
        return nil
    }

    private static func parseRawR(_ value: String) -> WireEventType? {
        if value == "RSV" { return .resolve }
        if value == "RTV" { return .retrieve }
        if value == "RTN" { return .returnEvent }
        return nil
    }
}

#if !hasFeature(Embedded)
extension WireEventType: RawRepresentable {
    /// The String raw value (e.g. `"ADV"`) for host callers.
    ///
    /// This bridge is unavailable in Embedded Swift. Use ``wireCode`` for
    /// byte-level access in Embedded builds.
    public typealias RawValue = String

    public var rawValue: String {
        switch self {
        case .advertise: return "ADV"
        case .deadvertise: return "DAD"
        case .channel: return "CHN"
        case .associate: return "ASC"
        case .ioValue: return "IOV"
        case .discover: return "DSC"
        case .resolve: return "RSV"
        case .query: return "QRY"
        case .retrieve: return "RTV"
        case .update: return "UPD"
        case .complete: return "CPL"
        case .call: return "CLL"
        case .returnEvent: return "RTN"
        }
    }

    public init?(rawValue: String) {
        guard let eventType = Self.parseRawValue(rawValue) else { return nil }
        self = eventType
    }
}
#endif

extension ByteSlice {
    /// Finds a byte value and returns the sub-slice after it, or nil.
    func findByte(_ target: UInt8) -> ByteSlice? {
        for i in 0..<length where pointer.load(fromByteOffset: i, as: UInt8.self) == target {
            let remaining = length - i - 1
            guard remaining > 0 else { return ByteSlice(pointer: pointer.advanced(by: i + 1), length: 0) }
            return ByteSlice(pointer: pointer.advanced(by: i + 1), length: remaining)
        }
        return nil
    }
}
