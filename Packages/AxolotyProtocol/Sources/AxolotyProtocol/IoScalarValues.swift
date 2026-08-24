// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire

extension Bool: JSONIoValue {
    /// Decodes a JSON Boolean.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        switch value.kind {
        case .trueValue: self = true
        case .falseValue: self = false
        default: throw .invalidValue
        }
    }

    /// Encodes a canonical JSON Boolean.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        if self {
            try output.write("true")
        } else {
            try output.write("false")
        }
    }
}

extension Int: JSONIoValue {
    /// Decodes a JSON integer within the platform `Int` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeSigned(value), decoded >= Int64(Int.min), decoded <= Int64(Int.max) else { throw .invalidValue }
        self = Int(decoded)
    }

    /// Encodes a canonical JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeSigned(Int64(self), into: &output)
    }
}
extension Int8: JSONIoValue {
    /// Decodes a JSON integer within the `Int8` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeSigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeSigned(Int64(self), into: &output)
    }
}
extension Int16: JSONIoValue {
    /// Decodes a JSON integer within the `Int16` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeSigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeSigned(Int64(self), into: &output)
    }
}
extension Int32: JSONIoValue {
    /// Decodes a JSON integer within the `Int32` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeSigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeSigned(Int64(self), into: &output)
    }
}
extension Int64: JSONIoValue {
    /// Decodes a JSON integer within the `Int64` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeSigned(value) else { throw .invalidValue }
        self = decoded
    }

    /// Encodes a canonical JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeSigned(self, into: &output)
    }
}

extension UInt: JSONIoValue {
    /// Decodes a nonnegative JSON integer within the platform `UInt` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeUnsigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical nonnegative JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeUnsigned(UInt64(self), into: &output)
    }
}
extension UInt8: JSONIoValue {
    /// Decodes a nonnegative JSON integer within the `UInt8` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeUnsigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical nonnegative JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeUnsigned(UInt64(self), into: &output)
    }
}
extension UInt16: JSONIoValue {
    /// Decodes a nonnegative JSON integer within the `UInt16` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeUnsigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical nonnegative JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeUnsigned(UInt64(self), into: &output)
    }
}
extension UInt32: JSONIoValue {
    /// Decodes a nonnegative JSON integer within the `UInt32` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeUnsigned(value), let result = Self(exactly: decoded) else { throw .invalidValue }
        self = result
    }

    /// Encodes a canonical nonnegative JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeUnsigned(UInt64(self), into: &output)
    }
}
extension UInt64: JSONIoValue {
    /// Decodes a nonnegative JSON integer within the `UInt64` range.
    public init(ioJSON value: borrowing JSONValueView) throws(IoValueError) {
        guard let decoded = decodeUnsigned(value) else { throw .invalidValue }
        self = decoded
    }

    /// Encodes a canonical nonnegative JSON integer.
    public func encodeIoJSON(into output: inout IoJSONOutput) throws(IoValueError) {
        try encodeUnsigned(self, into: &output)
    }
}

private func decodeSigned(_ value: borrowing JSONValueView) -> Int64? {
    var result: Int64?
    guard value.withNumber({ result = $0.intValue }) else { return nil }
    return result
}

private func decodeUnsigned(_ value: borrowing JSONValueView) -> UInt64? {
    var result: UInt64?
    guard value.withNumber({ result = $0.uintValue }) else { return nil }
    return result
}

private func encodeSigned(_ value: Int64, into output: inout IoJSONOutput) throws(IoValueError) {
    let negative = value < 0
    let magnitude = negative ? UInt64(-(value + 1)) + 1 : UInt64(value)
    try encodeMagnitude(magnitude, negative: negative, into: &output)
}

private func encodeUnsigned(_ value: UInt64, into output: inout IoJSONOutput) throws(IoValueError) {
    try encodeMagnitude(value, negative: false, into: &output)
}

private func encodeMagnitude(_ value: UInt64, negative: Bool, into output: inout IoJSONOutput) throws(IoValueError) {
    var bytes = InlineArray<21, UInt8>(repeating: 0)
    var magnitude = value
    var start = 21
    repeat {
        start -= 1
        bytes[start] = UInt8(magnitude % 10) + 48
        magnitude /= 10
    } while magnitude > 0
    if negative { start -= 1; bytes[start] = 45 }
    try withUnsafeBytes(of: bytes) { (buffer: UnsafeRawBufferPointer) throws(IoValueError) -> Void in
        try output.writeRaw(ByteSlice(
            bytes: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: start),
            length: 21 - start
        ))
    }
}
