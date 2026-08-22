// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import _JSONCore

/// The lexical kind of one complete JSON value.
public enum WireValueKind: UInt8, Sendable, Equatable {
    /// A JSON object.
    case object
    /// A JSON array.
    case array
    /// A JSON string.
    case string
    /// A JSON number.
    case number
    /// JSON `true`.
    case trueValue
    /// JSON `false`.
    case falseValue
    /// JSON `null`.
    case null
    /// No value was available.
    case invalid
}

enum WireValueReaderLimits {
    // One direct array element needs at least one payload byte. Therefore the
    // wire's measured 512-byte payload bound is also the exact direct-element
    // index bound; a 513th direct element is rejected deterministically.
    static let directArrayElementCapacity = 512
}

/// A borrowed view over one complete JSON value.
///
/// This is a small tokenizer-backed seam for portable consumers. It exposes
/// child ranges without introducing a second JSON parser in those consumers.
public struct WireValueReader: ~Copyable {
    private let bytes: UnsafeRawPointer
    /// The number of bytes in the value.
    public let length: Int

    /// Creates a reader over a borrowed complete JSON value.
    public init(_ value: ByteSlice) {
        self.bytes = value.withBytes { pointer, _ in pointer }
        self.length = value.length
    }

    /// The lexical kind of this value.
    public var kind: WireValueKind {
        guard let byte = byte(at: 0) else { return .invalid }
        switch byte {
        case 0x7B: return .object
        case 0x5B: return .array
        case 0x22: return .string
        case 0x2D, 0x30...0x39: return .number
        case 0x74: return .trueValue
        case 0x66: return .falseValue
        case 0x6E: return .null
        default: return .invalid
        }
    }

    /// Borrows each direct field of an object value.
    public borrowing func withObjectFields(_ body: (borrowing WireObjectField) -> Void) throws(WireDecodeError) {
        guard kind == .object else { throw WireDecodeError(.typeMismatch(expected: "object")) }
        let reader = WireReader(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        try reader.withObjectFields(body)
    }

    /// Borrows each direct element of an array value.
    public borrowing func withArrayElements(_ body: (ByteSlice) -> Void) throws(WireDecodeError) {
        guard kind == .array else { throw WireDecodeError(.typeMismatch(expected: "array")) }
        guard length <= WireBufferConfig.maxPayloadSize else {
            throw WireDecodeError(.payloadExceedsLimit, byteOffset: length)
        }

        let value = ByteSlice(bytes: bytes.assumingMemoryBound(to: UInt8.self), length: length)
        guard WireReader.isValidJSONValue(value) else {
            throw WireDecodeError(.unexpectedToken(expected: "valid JSON array", actual: byte(at: 0)))
        }

        var destination = WireArrayElementDestination(bytes: UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: length))
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: WireBufferConfig.maxPayloadSize + 8) { padded in
            padded.baseAddress!.initialize(from: bytes.assumingMemoryBound(to: UInt8.self), count: length)
            for offset in length..<(length + 8) { padded[offset] = 0x5D }
            var tokenizer = JSONTokenizer(
                bytes: UnsafeBufferPointer(start: padded.baseAddress!, count: length + 8),
                destination: destination
            )
            #if hasFeature(Embedded)
            _ = tokenizer.scanValueResult()
            #else
            try? tokenizer.scanValue()
            #endif
            destination = tokenizer.destination
        }
        guard destination.rootArray, destination.failure == nil else {
            throw destination.failure ?? WireDecodeError(.unexpectedToken(expected: "valid JSON array", actual: byte(at: 0)))
        }
        for index in 0..<destination.count {
            let range = destination.elements[index]
            body(ByteSlice(bytes: bytes.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self), length: range.count))
        }
    }

    /// Visits decoded Unicode scalar values in a JSON string.
    public borrowing func withStringScalars(_ body: (UInt32) -> Void) throws(WireDecodeError) {
        guard kind == .string, length >= 2, byte(at: length - 1) == 0x22 else {
            throw WireDecodeError(.typeMismatch(expected: "string"))
        }
        var cursor = WireKeyCursor(
            bytes: bytes,
            range: 1..<(length - 1),
            decodesEscapes: true
        )
        while let scalar = cursor.nextScalar() { body(scalar) }
        guard cursor.isValid else { throw WireDecodeError(.invalidEscape, byteOffset: 0) }
    }

    /// Returns a byte from the borrowed value.
    @inline(__always) private func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < length else { return nil }
        return bytes.load(fromByteOffset: index, as: UInt8.self)
    }
}

struct WireArrayElementDestination: JSONTokenizerDestination {
    typealias ArrayStartContext = WireArrayContext
    typealias ObjectStartContext = WireArrayContext

    let bytes: UnsafeBufferPointer<UInt8>
    var depth = 0
    var rootArray = false
    var failure: WireDecodeError?
    var count = 0
    // A direct array cannot contain more elements than its byte payload.
    // Keep this inline capacity equal to `directArrayElementCapacity`; the
    // generic argument is repeated as a literal because it is a const generic.
    var elements = InlineArray<512, Range<Int>>(repeating: 0..<0)

    mutating func arrayStartFound(_ token: JSONToken.ArrayStart) -> WireArrayContext {
        if depth == 0 { rootArray = true }
        let context = WireArrayContext(start: token.start.byteOffset, isRoot: depth == 0)
        depth += 1
        return context
    }

    mutating func arrayEndFound(_ token: JSONToken.ArrayEnd, context: consuming WireArrayContext) {
        depth -= 1
        if depth == 1 { append(context.start..<token.end.byteOffset) }
    }

    mutating func objectStartFound(_ token: JSONToken.ObjectStart) -> WireArrayContext {
        let context = WireArrayContext(start: token.start.byteOffset, isRoot: false)
        depth += 1
        return context
    }

    mutating func objectEndFound(_ token: JSONToken.ObjectEnd, context: consuming WireArrayContext) {
        depth -= 1
        if depth == 1 { append(context.start..<token.end.byteOffset) }
    }

    mutating func stringFound(_ token: JSONToken.String) {
        if depth == 1 { append(token.start.byteOffset..<token.end.byteOffset) }
    }

    mutating func numberFound(_ token: JSONToken.Number) {
        if depth == 1 { append(token.start.byteOffset..<token.end.byteOffset) }
    }

    mutating func booleanTrueFound(_ token: JSONToken.BooleanTrue) {
        if depth == 1 { append(token.start.byteOffset - 4..<token.start.byteOffset) }
    }

    mutating func booleanFalseFound(_ token: JSONToken.BooleanFalse) {
        if depth == 1 { append(token.start.byteOffset - 5..<token.start.byteOffset) }
    }

    mutating func nullFound(_ token: JSONToken.Null) {
        if depth == 1 { append(token.start.byteOffset - 4..<token.start.byteOffset) }
    }

    mutating func append(_ range: Range<Int>) {
        guard count < WireValueReaderLimits.directArrayElementCapacity else {
            if failure == nil { failure = WireDecodeError(.fieldIndexOverflow, byteOffset: range.lowerBound) }
            return
        }
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            if failure == nil { failure = WireDecodeError(.unexpectedEndOfInput, byteOffset: range.lowerBound) }
            return
        }
        elements[count] = range
        count += 1
    }
}

struct WireArrayContext {
    let start: Int
    let isRoot: Bool
}
