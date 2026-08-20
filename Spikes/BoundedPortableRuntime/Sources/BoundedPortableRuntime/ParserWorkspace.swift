// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The accepted payload limit, independent from physical workspace capacity.
public let boundedPayloadLimit = 512

/// A fixed byte input shared by host and Embedded Swift parser runs.
public struct InlineParserInput<let capacity: Int>: ~Copyable {
    private var bytes: InlineArray<capacity, UInt8>
    private let length: Int

    /// Creates an input with `count` repeated bytes.
    public init(repeating byte: UInt8, count: Int) {
        precondition(count <= capacity)
        bytes = InlineArray(repeating: byte)
        length = count
    }

    /// Number of bytes exposed to the parser.
    public var count: Int { length }

    /// Reads one byte by bounded index.
    public subscript(index: Int) -> UInt8 { bytes[index] }
}

/// A fixed parser workspace with a payload limit independent from capacity.
public struct ParserWorkspace<let capacity: Int>: ~Copyable {
    private var bytes: InlineArray<capacity, UInt8>
    private var length = 0

    /// Creates a zeroed reusable workspace.
    public init() { bytes = InlineArray(repeating: 0) }

    /// Parses a payload without growing storage.
    public mutating func parse<let inputCapacity: Int>(
        _ payload: borrowing InlineParserInput<inputCapacity>
    ) -> Bool {
        guard payload.count <= boundedPayloadLimit, payload.count <= capacity else { return false }
        length = 0
        for index in 0..<payload.count {
            bytes[length] = payload[index]
            length += 1
        }
        return true
    }

    /// Returns the bytes written by the last successful parse.
    public func snapshot() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        for index in 0..<length { result.append(bytes[index]) }
        return result
    }
}

/// A host workspace deliberately larger than the embedded inline workspace.
public struct HostParserWorkspace: ~Copyable {
    private var bytes: UnsafeMutableBufferPointer<UInt8>
    private var length = 0

    /// Creates one reusable contiguous host buffer.
    public init(capacity: Int = 4096) {
        bytes = UnsafeMutableBufferPointer.allocate(capacity: capacity)
        bytes.initialize(repeating: 0)
    }

    deinit { bytes.deallocate() }

    /// Parses the same payload algorithm as `ParserWorkspace`.
    public mutating func parse<let inputCapacity: Int>(
        _ payload: borrowing InlineParserInput<inputCapacity>
    ) -> Bool {
        guard payload.count <= boundedPayloadLimit, payload.count <= bytes.count else { return false }
        length = 0
        for index in 0..<payload.count { bytes[length] = payload[index]; length += 1 }
        return true
    }

    /// Returns the bytes written by the last successful parse.
    public func snapshot() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        for index in 0..<length { result.append(bytes[index]) }
        return result
    }
}
