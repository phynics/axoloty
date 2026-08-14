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
    private var _levelCount: Int

    /// Start offsets of up to 7 parsed topic levels within ``bytes``.
    @usableFromInline internal var levelOffsets: (Int, Int, Int, Int, Int, Int, Int)
    /// Lengths of up to 7 parsed topic levels within ``bytes``.
    @usableFromInline internal var levelLengths: (Int, Int, Int, Int, Int, Int, Int)

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
        self.byteCount = length
        self.levelOffsets = (0, 0, 0, 0, 0, 0, 0)
        self.levelLengths = (0, 0, 0, 0, 0, 0, 0)
        self._levelCount = 0
        parseLevels()
    }

    private mutating func parseLevels() {
        var start = 0
        var count = 0
        for i in 0..<byteCount where bytes.load(fromByteOffset: i, as: UInt8.self) == 0x2F {
            if count < 7 {
                setLevel(count, offset: start, length: i - start)
            }
            count += 1
            start = i + 1
        }
        // Last segment after final '/'
        if start < byteCount && count < 7 {
            setLevel(count, offset: start, length: byteCount - start)
            count += 1
        } else if start == byteCount {
            // Trailing '/' — empty last segment, already counted
        } else if count < 7 {
            setLevel(count, offset: start, length: byteCount - start)
            count += 1
        }
        _levelCount = count
    }

    @inline(__always)
    private mutating func setLevel(_ index: Int, offset: Int, length: Int) {
        switch index {
        case 0: (levelOffsets.0, levelLengths.0) = (offset, length)
        case 1: (levelOffsets.1, levelLengths.1) = (offset, length)
        case 2: (levelOffsets.2, levelLengths.2) = (offset, length)
        case 3: (levelOffsets.3, levelLengths.3) = (offset, length)
        case 4: (levelOffsets.4, levelLengths.4) = (offset, length)
        case 5: (levelOffsets.5, levelLengths.5) = (offset, length)
        case 6: (levelOffsets.6, levelLengths.6) = (offset, length)
        default: break
        }
    }

    @inline(__always)
    private func levelOffset(_ index: Int) -> Int {
        switch index {
        case 0: return levelOffsets.0
        case 1: return levelOffsets.1
        case 2: return levelOffsets.2
        case 3: return levelOffsets.3
        case 4: return levelOffsets.4
        case 5: return levelOffsets.5
        case 6: return levelOffsets.6
        default: return 0
        }
    }

    @inline(__always)
    private func levelLength(_ index: Int) -> Int {
        switch index {
        case 0: return levelLengths.0
        case 1: return levelLengths.1
        case 2: return levelLengths.2
        case 3: return levelLengths.3
        case 4: return levelLengths.4
        case 5: return levelLengths.5
        case 6: return levelLengths.6
        default: return 0
        }
    }

    /// Returns the bytes of the topic level at the given index, or nil.
    public func level(_ index: Int) -> ByteSlice? {
        guard index < _levelCount else { return nil }
        let len = levelLength(index)
        guard len > 0 else { return ByteSlice(pointer: bytes.advanced(by: levelOffset(index)), length: 0) }
        return ByteSlice(pointer: bytes.advanced(by: levelOffset(index)), length: len)
    }

    /// The event type parsed from level 3, or nil if unrecognized.
    /// Handles event levels with optional filters (e.g. "ADV:sensors").
    public var eventType: WireEventType? {
        guard let eventLevel = level(3) else { return nil }
        // Event code is the first 3 bytes (before optional ':' filter)
        guard eventLevel.length >= 3 else { return nil }
        let code = eventLevel.subSlice(from: 0, length: 3)
        return WireEventType(wireCode: code)
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
