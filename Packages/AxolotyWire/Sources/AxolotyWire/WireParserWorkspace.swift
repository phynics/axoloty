// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// Caller-owned storage used by the single-pass wire JSON tokenizer.
///
/// The workspace is a temporary tokenizer scratch area only: indexed fields
/// continue to borrow the caller's input buffer, and no workspace bytes escape
/// the synchronous reader initializer. A workspace smaller than the accepted
/// payload limit plus its guard bytes is reported by ``WireReader`` as a
/// structured decode failure.
public protocol WireParserWorkspace: ~Copyable {
    /// Physical byte capacity available to the tokenizer.
    var capacity: Int { get }

    /// Provides mutable scratch bytes for one tokenizer invocation.
    mutating func withStorage<R>(
        _ body: (UnsafeMutableBufferPointer<UInt8>) -> R
    ) -> R
}

/// Fixed inline tokenizer storage for Embedded Swift.
public struct InlineWireParserWorkspace<let capacity: Int>: ~Copyable, WireParserWorkspace {
    private var bytes: InlineArray<capacity, UInt8>

    /// Creates zeroed inline storage.
    public init() {
        bytes = InlineArray(repeating: 0)
    }

    /// The compile-time inline capacity.
    public var capacity: Int { capacity }

    /// Borrows the inline bytes for one tokenizer invocation.
    public mutating func withStorage<R>(
        _ body: (UnsafeMutableBufferPointer<UInt8>) -> R
    ) -> R {
        withUnsafeMutableBytes(of: &bytes) { raw in
            let buffer = UnsafeMutableBufferPointer(
                start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                count: raw.count
            )
            return body(buffer)
        }
    }
}

/// The measured 2,056-byte embedded workspace for a 2,048-byte accepted payload.
public typealias EmbeddedWireParserWorkspace = InlineWireParserWorkspace<2056>

/// Reusable contiguous host tokenizer storage.
public struct HostWireParserWorkspace: ~Copyable, WireParserWorkspace {
    private var bytes: UnsafeMutableBufferPointer<UInt8>

    /// Creates reusable host storage.
    ///
    /// - Parameter capacity: Physical workspace capacity. This is independent
    ///   from the 2,048-byte accepted wire payload limit.
    public init(capacity: Int = 4096) {
        bytes = UnsafeMutableBufferPointer.allocate(capacity: max(0, capacity))
        bytes.initialize(repeating: 0)
    }

    deinit {
        bytes.deallocate()
    }

    /// The physical host workspace capacity.
    public var capacity: Int { bytes.count }

    /// Borrows the reusable host bytes for one tokenizer invocation.
    public mutating func withStorage<R>(
        _ body: (UnsafeMutableBufferPointer<UInt8>) -> R
    ) -> R {
        body(bytes)
    }
}
