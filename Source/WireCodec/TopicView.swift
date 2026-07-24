// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Zero-allocation parsing of a Coaty MQTT topic string.
///
/// Replaces the class-based `CommunicationTopic` and its
/// `String.components(separatedBy:)` array allocation with a borrowed view
/// that scans the topic bytes in-place. Topic levels are returned as
/// `ByteSlice` — no String or Array is allocated.
///
/// The Coaty topic structure is:
/// `coaty/<version>/<namespace>/<eventType>[filter]/<sourceId>[/<correlationId>]`
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
        for i in 0..<byteCount {
            if bytes.load(fromByteOffset: i, as: UInt8.self) == 0x2F { // '/'
                if count < 7 {
                    setLevel(count, offset: start, length: i - start)
                }
                count += 1
                start = i + 1
            }
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
        if code.equals("ADV") { return .advertise }
        if code.equals("DAD") { return .deadvertise }
        if code.equals("CHN") { return .channel }
        if code.equals("ASC") { return .associate }
        if code.equals("IOV") { return .ioValue }
        if code.equals("DSC") { return .discover }
        if code.equals("RSV") { return .resolve }
        if code.equals("QRY") { return .query }
        if code.equals("RTV") { return .retrieve }
        if code.equals("UPD") { return .update }
        if code.equals("CPL") { return .complete }
        if code.equals("CLL") { return .call }
        if code.equals("RTN") { return .returnEvent }
        return nil
    }

    /// The event-type filter (the part after ':' in level 3), if present.
    public var eventTypeFilter: ByteSlice? {
        guard let eventLevel = level(3) else { return nil }
        return eventLevel.findByte(0x3A) // ':'
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

/// Foundation-free event type enum, mirroring `CommunicationEventType`.
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
}

extension ByteSlice {
    /// Finds a byte value and returns the sub-slice after it, or nil.
    func findByte(_ target: UInt8) -> ByteSlice? {
        for i in 0..<length {
            if pointer.load(fromByteOffset: i, as: UInt8.self) == target {
                let remaining = length - i - 1
                guard remaining > 0 else { return ByteSlice(pointer: pointer.advanced(by: i + 1), length: 0) }
                return ByteSlice(pointer: pointer.advanced(by: i + 1), length: remaining)
            }
        }
        return nil
    }
}
