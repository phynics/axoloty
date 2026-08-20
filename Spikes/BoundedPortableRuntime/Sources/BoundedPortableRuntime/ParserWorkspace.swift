// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The accepted payload limit, independent from physical workspace capacity.
public let boundedPayloadLimit = 512

private protocol MutableParserStorage: ~Copyable {
    var storageCapacity: Int { get }
    mutating func resetStorage()
    mutating func appendToStorage(_ byte: UInt8)
}

private func parsePayload<let inputCapacity: Int, Storage: MutableParserStorage & ~Copyable>(
    _ payload: borrowing InlineParserInput<inputCapacity>,
    into storage: inout Storage
) -> Bool {
    guard payload.count <= boundedPayloadLimit,
          payload.count <= storage.storageCapacity else { return false }
    storage.resetStorage()
    for index in 0..<payload.count { storage.appendToStorage(payload[index]) }
    return true
}

/// A fixed byte input shared by host and Embedded Swift parser runs.
public struct InlineParserInput<let capacity: Int>: ~Copyable {
    private var bytes: InlineArray<capacity, UInt8>
    private let length: Int

    /// Creates an input with `count` repeated bytes.
    ///
    /// - Parameters:
    ///   - byte: Byte used to initialize the input.
    ///   - count: Logical payload length, which must not exceed `capacity`.
    public init(repeating byte: UInt8, count: Int) {
        precondition(count <= capacity)
        bytes = InlineArray(repeating: byte)
        length = count
    }

    /// Number of bytes exposed to the parser.
    public var count: Int { length }

    /// Reads one byte by bounded index.
    ///
    /// - Parameter index: Index less than ``count``.
    public subscript(index: Int) -> UInt8 { bytes[index] }
}

/// A fixed parser workspace with a payload limit independent from capacity.
public struct ParserWorkspace<let capacity: Int>: ~Copyable, MutableParserStorage {
    private var bytes: InlineArray<capacity, UInt8>
    private var length = 0

    /// Creates a zeroed reusable workspace.
    public init() { bytes = InlineArray(repeating: 0) }

    /// Parses a payload without growing storage.
    ///
    /// - Parameter payload: Fixed input accepted by the shared parser algorithm.
    /// - Returns: Whether the payload fit both the protocol limit and workspace.
    public mutating func parse<let inputCapacity: Int>(
        _ payload: borrowing InlineParserInput<inputCapacity>
    ) -> Bool {
        parsePayload(payload, into: &self)
    }

    /// Returns the bytes written by the last successful parse.
    public func snapshot() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        for index in 0..<length { result.append(bytes[index]) }
        return result
    }

    fileprivate var storageCapacity: Int { capacity }
    fileprivate mutating func resetStorage() { length = 0 }
    fileprivate mutating func appendToStorage(_ byte: UInt8) {
        bytes[length] = byte
        length += 1
    }
}

/// A host workspace deliberately larger than the embedded inline workspace.
public struct HostParserWorkspace: ~Copyable, MutableParserStorage {
    private var bytes: UnsafeMutableBufferPointer<UInt8>
    private var length = 0

    /// Creates one reusable contiguous host buffer.
    ///
    /// - Parameter capacity: Physical workspace size, independent of the
    ///   accepted payload limit.
    public init(capacity: Int = 4096) {
        bytes = UnsafeMutableBufferPointer.allocate(capacity: capacity)
        bytes.initialize(repeating: 0)
    }

    deinit { bytes.deallocate() }

    /// Parses with the same generic algorithm as ``ParserWorkspace``.
    ///
    /// - Parameter payload: Fixed input accepted by the shared parser algorithm.
    /// - Returns: Whether the payload fit both the protocol limit and workspace.
    public mutating func parse<let inputCapacity: Int>(
        _ payload: borrowing InlineParserInput<inputCapacity>
    ) -> Bool {
        parsePayload(payload, into: &self)
    }

    /// Returns the bytes written by the last successful parse.
    public func snapshot() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        for index in 0..<length { result.append(bytes[index]) }
        return result
    }

    fileprivate var storageCapacity: Int { bytes.count }
    fileprivate mutating func resetStorage() { length = 0 }
    fileprivate mutating func appendToStorage(_ byte: UInt8) {
        bytes[length] = byte
        length += 1
    }
}
