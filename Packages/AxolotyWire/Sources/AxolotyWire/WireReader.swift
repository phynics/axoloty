// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

/// The token kind of one field visited in a JSON object.
public enum WireObjectFieldKind: UInt8, Sendable {
    /// Object value.
    case object
    /// Array value.
    case array
    /// String value.
    case string
    /// Number value.
    case number
    /// Boolean true.
    case trueValue
    /// Boolean false.
    case falseValue
    /// Null value.
    case null
}

/// A borrowed top-level object field produced by ``WireReader/withObjectFields(_:)``.
public struct WireObjectField: ~Copyable {
    @usableFromInline let bytes: UnsafeRawPointer
    /// The decoded key content range, excluding JSON quotes.
    public let keyRange: Range<Int>
    /// The complete value range, including container delimiters or quotes.
    public let valueRange: Range<Int>
    /// The lexical value kind.
    public let kind: WireObjectFieldKind

    /// Compares the decoded key against a static key using JSON escape semantics.
    public borrowing func keyEquals(_ key: StaticString) -> Bool {
        let pointer = bytes.advanced(by: keyRange.lowerBound)
        var left = WireKeyCursor(bytes: pointer, range: 0..<keyRange.count, decodesEscapes: true)
        var right = WireKeyCursor(key: key)
        return wireSemanticKeysEqual(&left, &right)
    }

    /// Borrows the decoded key content for the duration of `body`.
    public borrowing func withKey(_ body: (ByteSlice) -> Void) {
        body(ByteSlice(bytes: bytes.advanced(by: keyRange.lowerBound).assumingMemoryBound(to: UInt8.self), length: keyRange.count))
    }

    /// Borrows decoded key bytes as a noncopyable scoped view.
    public borrowing func withBorrowedKey(_ body: (borrowing WireValueView) -> Void) {
        body(WireValueView(
            bytes: bytes.advanced(by: keyRange.lowerBound),
            length: keyRange.count
        ))
    }

    /// Borrows the complete encoded value for the duration of `body`.
    public borrowing func withValue(_ body: (ByteSlice) -> Void) {
        body(ByteSlice(bytes: bytes.advanced(by: valueRange.lowerBound).assumingMemoryBound(to: UInt8.self), length: valueRange.count))
    }

    /// Borrows the complete encoded field value as a noncopyable scoped view.
    public borrowing func withBorrowedValue(_ body: (borrowing WireValueView) -> Void) {
        body(WireValueView(
            bytes: bytes.advanced(by: valueRange.lowerBound),
            length: valueRange.count
        ))
    }
}

/// The lexical kind retained for an indexed JSON value.
@usableFromInline enum WireTokenKind: UInt8 { case object, array, string, number, trueValue, falseValue, nullValue }

struct WireKeyCursor {
    private let bytes: UnsafeRawPointer
    private let end: Int
    private let decodesEscapes: Bool
    private var offset: Int
    private(set) var isValid = true

    init(bytes: UnsafeRawPointer, range: Range<Int>, decodesEscapes: Bool) {
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = range.upperBound
        self.decodesEscapes = decodesEscapes
    }

    init(key: StaticString) {
        self.init(
            bytes: UnsafeRawPointer(key.utf8Start),
            range: 0..<key.utf8CodeUnitCount,
            decodesEscapes: false
        )
    }

    mutating func nextScalar() -> UInt32? {
        guard isValid, offset < end else { return nil }
        let firstByte = loadByte(at: offset)
        if decodesEscapes && firstByte == 0x5C { return escapedScalar() }
        if firstByte < 0x80 {
            offset += 1
            return UInt32(firstByte)
        }
        return utf8Scalar(firstByte: firstByte)
    }

    private mutating func utf8Scalar(firstByte: UInt8) -> UInt32? {
        guard let width = utf8Width(firstByte), width <= end - offset else { return invalidate() }
        let second = loadByte(at: offset + 1)
        guard second >= 0x80 && second <= 0xBF else { return invalidate() }
        guard !((firstByte == 0xE0 && second < 0xA0) || (firstByte == 0xED && second > 0x9F) ||
                 (firstByte == 0xF0 && second < 0x90) || (firstByte == 0xF4 && second > 0x8F)) else {
            return invalidate()
        }
        if width > 2 {
            for continuation in 2..<width {
                let byte = loadByte(at: offset + continuation)
                guard byte >= 0x80 && byte <= 0xBF else { return invalidate() }
            }
        }
        let scalar = utf8ScalarValue(firstByte: firstByte, second: second, width: width)
        offset += width
        return scalar
    }

    private func utf8Width(_ byte: UInt8) -> Int? {
        switch byte {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    private func utf8ScalarValue(firstByte: UInt8, second: UInt8, width: Int) -> UInt32 {
        switch width {
        case 2: return (UInt32(firstByte & 0x1F) << 6) | UInt32(second & 0x3F)
        case 3:
            return (UInt32(firstByte & 0x0F) << 12) | (UInt32(second & 0x3F) << 6) |
                UInt32(loadByte(at: offset + 2) & 0x3F)
        case 4:
            return (UInt32(firstByte & 0x07) << 18) | (UInt32(second & 0x3F) << 12) |
                (UInt32(loadByte(at: offset + 2) & 0x3F) << 6) | UInt32(loadByte(at: offset + 3) & 0x3F)
        default: return 0
        }
    }

    private mutating func escapedScalar() -> UInt32? {
        guard end - offset >= 2 else { return invalidate() }
        let marker = loadByte(at: offset + 1)
        if marker == 0x75 { return unicodeEscapedScalar() }
        guard let scalar = simpleEscapeScalar(marker) else { return invalidate() }
        offset += 2
        return scalar
    }

    private func simpleEscapeScalar(_ marker: UInt8) -> UInt32? {
        switch marker {
        case 0x22: return 0x22
        case 0x5C: return 0x5C
        case 0x2F: return 0x2F
        case 0x62: return 0x08
        case 0x66: return 0x0C
        case 0x6E: return 0x0A
        case 0x72: return 0x0D
        case 0x74: return 0x09
        default: return nil
        }
    }

    private mutating func unicodeEscapedScalar() -> UInt32? {
        guard end - offset >= 6, let high = unicodeEscape(at: offset + 2) else { return invalidate() }
        offset += 6
        if high >= 0xD800 && high <= 0xDBFF { return surrogatePairScalar(high) }
        guard high < 0xD800 || high > 0xDFFF else { return invalidate() }
        return high
    }

    private mutating func surrogatePairScalar(_ high: UInt32) -> UInt32? {
        guard end - offset >= 6, loadByte(at: offset) == 0x5C, loadByte(at: offset + 1) == 0x75,
              let low = unicodeEscape(at: offset + 2), low >= 0xDC00, low <= 0xDFFF
        else { return invalidate() }
        offset += 6
        return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
    }

    private func unicodeEscape(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= end, end - offset >= 4 else { return nil }
        var value: UInt32 = 0
        for digitOffset in 0..<4 {
            let digitByte = loadByte(at: offset + digitOffset)
            let digit: UInt32
            if digitByte >= 48 && digitByte <= 57 { digit = UInt32(digitByte - 48) }
            else if digitByte >= 65 && digitByte <= 70 { digit = UInt32(digitByte - 55) }
            else if digitByte >= 97 && digitByte <= 102 { digit = UInt32(digitByte - 87) }
            else { return nil }
            value = value * 16 + digit
        }
        return value
    }

    @inline(__always) private func loadByte(at offset: Int) -> UInt8 {
        bytes.load(fromByteOffset: offset, as: UInt8.self)
    }

    private mutating func invalidate() -> UInt32? {
        isValid = false
        offset = end
        return nil
    }
}

func wireSemanticKeysEqual(_ lhs: inout WireKeyCursor, _ rhs: inout WireKeyCursor) -> Bool {
    while true {
        let left = lhs.nextScalar()
        let right = rhs.nextScalar()
        if left == nil || right == nil { return left == nil && right == nil && lhs.isValid && rhs.isValid }
        if left != right { return false }
    }
}

func wireSemanticKeysEqual(bytes: UnsafeRawPointer, range: Range<Int>, key: StaticString) -> Bool {
    var field = WireKeyCursor(bytes: bytes, range: range, decodesEscapes: true)
    var requested = WireKeyCursor(key: key)
    return wireSemanticKeysEqual(&field, &requested)
}

func wireSemanticKeysEqual(bytes: UnsafeBufferPointer<UInt8>, lhs: Range<Int>, rhs: Range<Int>) -> Bool {
    guard let baseAddress = bytes.baseAddress else { return false }
    var first = WireKeyCursor(bytes: UnsafeRawPointer(baseAddress), range: lhs, decodesEscapes: true)
    var second = WireKeyCursor(bytes: UnsafeRawPointer(baseAddress), range: rhs, decodesEscapes: true)
    return wireSemanticKeysEqual(&first, &second)
}

/// A Foundation-free reader which tokenizes once into bounded borrowed slots.
public struct WireReader {
    @usableFromInline let bytes: UnsafeRawPointer
    public let length: Int
    @usableFromInline let index: WireFieldIndex

    /// Creates a reader over a borrowed JSON byte buffer.
    ///
    /// Inputs larger than ``WireBufferConfig.maxPayloadSize`` are rejected
    /// before tokenizer workspace is initialized. Accepted inputs use a
    /// fixed-size tokenizer workspace with eight guard bytes; indexed values
    /// continue to borrow from the caller's original buffer.
    ///
    /// - Note: The tokenizer workspace is an inline/temporary allocation sized
    ///   to a constant ``WireBufferConfig.maxPayloadSize`` + 8 bytes and is
    ///   not a function of the input length. On Swift 6.3 host builds it is
    ///   stack-resident (no heap allocation in the steady state); on Embedded
    ///   Swift the allocation class is measured by the device `hotPathAllocations`
    ///   gate rather than assumed. This initializer performs a bounded memcpy of
    ///   the payload into the workspace but never allocates `String`, `Array`,
    ///   or an intermediate JSON value tree.
    public init(bytes: UnsafePointer<UInt8>, length: Int) {
        self.bytes = UnsafeRawPointer(bytes); self.length = max(0, length)
        let buffer = UnsafeBufferPointer(start: bytes, count: max(0, length))
        var index = WireFieldIndex()
        guard buffer.count <= WireBufferConfig.maxPayloadSize else {
            index.failure = WireDecodeError(.payloadExceedsLimit, byteOffset: buffer.count)
            self.index = index
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize + 8) { padded in
            if buffer.count > 0 {
                padded.baseAddress!.initialize(from: buffer.baseAddress!, count: buffer.count)
            }
            for offset in buffer.count..<(buffer.count + 8) { padded[offset] = 0x7D }
            index = Self.tokenize(
                buffer: buffer,
                padded: UnsafeBufferPointer(start: padded.baseAddress!, count: buffer.count + 8)
            )
        }
        self.index = index
    }

    /// Creates a reader using caller-owned tokenizer scratch storage.
    ///
    /// Host callers can keep one ``HostWireParserWorkspace`` and Embedded
    /// callers can provide ``EmbeddedWireParserWorkspace``. The parser and
    /// validation algorithm is identical to the default initializer; only the
    /// physical scratch storage changes.
    ///
    /// - Parameters:
    ///   - bytes: Pointer to the borrowed JSON input.
    ///   - length: Number of valid input bytes.
    ///   - workspace: Reusable tokenizer storage owned by the caller.
    public init<Workspace: WireParserWorkspace & ~Copyable>(
        bytes: UnsafePointer<UInt8>,
        length: Int,
        workspace: inout Workspace
    ) {
        self.bytes = UnsafeRawPointer(bytes); self.length = max(0, length)
        let buffer = UnsafeBufferPointer(start: bytes, count: max(0, length))
        var index = WireFieldIndex()
        guard buffer.count <= WireBufferConfig.maxPayloadSize else {
            index.failure = WireDecodeError(.payloadExceedsLimit, byteOffset: buffer.count)
            self.index = index
            return
        }
        let requiredCapacity = WireBufferConfig.maxPayloadSize + 8
        guard workspace.capacity >= requiredCapacity else {
            index.failure = WireDecodeError(.workspaceExceedsLimit, byteOffset: workspace.capacity)
            self.index = index
            return
        }
        workspace.withStorage { padded in
            if buffer.count > 0 {
                padded.baseAddress!.initialize(from: buffer.baseAddress!, count: buffer.count)
            }
            for offset in buffer.count..<(buffer.count + 8) { padded[offset] = 0x7D }
            index = Self.tokenize(buffer: buffer, padded: UnsafeBufferPointer(padded))
        }
        self.index = index
    }

    /// Validates that the complete input is one JSON object.
    public func validate() throws(WireDecodeError) {
        if let failure = index.failure { throw failure }
        guard index.rootObject else { throw WireDecodeError(.typeMismatch(expected: "object")) }
    }

    /// Visits every top-level field using the same bounded tokenizer as all
    /// other wire reads. Keys are compared semantically by the tokenizer, so
    /// escaped-equivalent names and duplicate names are handled consistently.
    /// The current portable index accepts at most 24 top-level fields;
    /// exceeding that bound throws ``WireDecodeError/Reason/fieldIndexOverflow``.
    public func withObjectFields(_ body: (borrowing WireObjectField) -> Void) throws(WireDecodeError) {
        try validate()
        for index in 0..<self.index.count {
            guard let slot = self.index.slot(index),
                  let kind = WireObjectFieldKind(rawValue: slot.kind.rawValue) else {
                throw WireDecodeError(.unexpectedEndOfInput, byteOffset: length)
            }
            body(WireObjectField(
                bytes: bytes,
                keyRange: slot.key,
                valueRange: slot.value,
                kind: kind
            ))
        }
    }

    /// Returns whether the complete input is one JSON value.
    public static func isValidJSON(_ bytes: ByteSlice) -> Bool { isValidJSONValue(bytes) }

    /// Returns whether the complete input is one JSON value, including scalars.
    public static func isValidJSONValue(_ bytes: ByteSlice) -> Bool {
        bytes.withBytes { pointer, count in
            guard count > 0, count <= WireBufferConfig.maxPayloadSize else { return false }
            if Int(bitPattern: pointer) % MemoryLayout<UInt64>.alignment != 0 {
                guard count <= WireBufferConfig.maxPayloadSize else { return false }
                var alignedStorage = SIMD64<UInt64>(repeating: 0)
                return withUnsafeMutableBytes(of: &alignedStorage) { storage in
                    for offset in 0..<count {
                        storage[offset] = pointer.load(fromByteOffset: offset, as: UInt8.self)
                    }
                    let aligned = storage.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    let reader = WireReader(bytes: aligned, length: count)
                    return reader.index.failure == nil && reader.index.completeValue
                }
            }
            let reader = WireReader(bytes: pointer.assumingMemoryBound(to: UInt8.self), length: count)
            return reader.index.failure == nil && reader.index.completeValue
        }
    }

    private static func tokenize(
        buffer: UnsafeBufferPointer<UInt8>,
        padded: UnsafeBufferPointer<UInt8>
    ) -> WireFieldIndex {
        let destination = WireFieldDestination(bytes: buffer)
        var tokenizer = JSONTokenizer(bytes: padded, destination: destination)
        #if hasFeature(Embedded)
        if let parserError = tokenizer.scanValueResult() {
            let missingData: Bool
            if case .missingData = parserError { missingData = true } else { missingData = false }
            tokenizer.destination.failure = Self.parserFailure(
                buffer,
                offset: tokenizer.currentOffset,
                destination: tokenizer.destination,
                parserErrorIsMissingData: missingData
            )
        }
        #else
        do {
            try tokenizer.scanValue()
        } catch {
            let missingData: Bool
            if case .missingData = error {
                missingData = true
            } else {
                missingData = false
            }
            tokenizer.destination.failure = Self.parserFailure(
                buffer,
                offset: tokenizer.currentOffset,
                destination: tokenizer.destination,
                parserErrorIsMissingData: missingData
            )
        }
        #endif
        return Self.finalizedIndex(
            tokenizer.destination,
            bytes: buffer,
            currentOffset: tokenizer.currentOffset
        )
    }

    /// Returns the complete raw JSON value for a top-level key.
    public func readField(_ key: StaticString) -> ByteSlice? {
        guard index.failure == nil, let range = index.find(bytes: bytes, key: key) else { return nil }
        return slice(range.value)
    }

    /// Returns string content without quotes. The returned bytes retain JSON
    /// escape sequences and must be treated as encoded string content.
    public func readString(_ key: StaticString) -> ByteSlice? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind == .string else { return nil }
        return slice(slot.content)
    }

    /// Reads a canonical JSON UUID string.
    public func readUUID(_ key: StaticString) -> UUID16? { readString(key).flatMap(UUID16.init(parsing:)) }

    /// Reads a JSON integer, rejecting other token kinds and overflow.
    public func readInt(_ key: StaticString) -> Int? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind == .number,
              let value = slice(slot.value) else { return nil }
        var result = 0; var negative = false; var offset = 0
        if value.byte(at: 0) == 0x2D { negative = true; offset = 1 }
        let first = offset
        while offset < value.length {
            guard let byte = value.byte(at: offset), byte >= 48 && byte <= 57 else { return nil }
            let (product, productOverflow) = result.multipliedReportingOverflow(by: 10)
            let (next, digitOverflow) = negative ? product.subtractingReportingOverflow(Int(byte - 48)) : product.addingReportingOverflow(Int(byte - 48))
            guard !productOverflow && !digitOverflow else { return nil }
            result = next; offset += 1
        }
        return offset == first ? nil : result
    }

    /// Reads a JSON boolean, rejecting other token kinds.
    public func readBool(_ key: StaticString) -> Bool? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key) else { return nil }
        if slot.kind == .trueValue { return true }; if slot.kind == .falseValue { return false }; return nil
    }

    /// Reads a complete raw JSON value, including quotes for strings.
    public func readRaw(_ key: StaticString) -> ByteSlice? { readField(key) }

    /// Reads an optional raw value, treating an explicit JSON `null` as absent.
    public func readOptionalRaw(_ key: StaticString) -> ByteSlice? {
        guard index.failure == nil, let slot = index.find(bytes: bytes, key: key), slot.kind != .nullValue else { return nil }
        return slice(slot.value)
    }

    @inline(__always) private func slice(_ range: Range<Int>) -> ByteSlice? {
        guard range.lowerBound >= 0, range.lowerBound <= range.upperBound, range.upperBound <= length else { return nil }
        return ByteSlice(pointer: bytes.advanced(by: range.lowerBound), length: range.count)
    }
    @inline(__always) private static func isWhitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }

    private static func finalizedIndex(
        _ initialDestination: WireFieldDestination,
        bytes: UnsafeBufferPointer<UInt8>,
        currentOffset: Int
    ) -> WireFieldIndex {
        var destination = initialDestination
        if destination.failure == nil && currentOffset > bytes.count {
            destination.failure = WireDecodeError(.unexpectedEndOfInput, byteOffset: bytes.count)
        } else {
            var offset = currentOffset
            while offset < bytes.count && isWhitespace(bytes[offset]) { offset += 1 }
            if destination.failure == nil && offset != bytes.count {
                destination.failure = WireDecodeError(
                    .unexpectedToken(expected: "end of input", actual: bytes[offset]),
                    byteOffset: offset
                )
            }
        }
        return destination.index
    }

    private static func parserFailure(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        destination: WireFieldDestination,
        parserErrorIsMissingData: Bool
    ) -> WireDecodeError {
        if let failure = destination.failure { return failure }
        if parserErrorIsMissingData {
            return .init(.unexpectedEndOfInput, byteOffset: bytes.count)
        }
        guard offset < bytes.count else { return .init(.unexpectedEndOfInput, byteOffset: bytes.count) }
        let byte = bytes[offset]
        if byte == 0x74 || byte == 0x66 || byte == 0x6E { return .init(.invalidLiteral, byteOffset: offset) }
        if byte == 0x2D || byte >= 0x30 && byte <= 0x39 { return .init(.invalidNumber, byteOffset: offset) }
        if (byte == 0x7D && destination.topContainer != 0x7B) || (byte == 0x5D && destination.topContainer != 0x5B) {
            return .init(.invalidNesting, byteOffset: offset)
        }
        return .init(.unexpectedToken(expected: "valid JSON", actual: byte), byteOffset: offset)
    }
}
