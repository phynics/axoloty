// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation

/// Loads the versioned fixture vectors used by the Axoloty Zenoh façade
/// conformance suite.
public enum ZenohFacadeContract {
    /// Decodes the fixture bundled with this target.
    ///
    /// - Returns: The contract version and its shared test vectors.
    /// - Throws: ``FixtureError`` if the fixture is missing or invalid.
    public static func load() throws(FixtureError) -> Document {
        guard let url = Bundle.module.url(forResource: "axoloty-zenoh-facade-v1", withExtension: "json") else {
            throw .resourceMissing
        }
        do {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw .invalidDocument
        }
    }

    /// The version and vectors defined by the bundled conformance fixture.
    public struct Document: Decodable {
        /// The SemVer contract identifier, such as `1.0.0`.
        public let contractVersion: String
        /// The shared vectors for each required façade behavior.
        public let vectors: Vectors
    }

    /// The fixtures shared by all façade backend conformance runs.
    public struct Vectors: Decodable {
        /// A binary round-trip key and payload.
        public let roundTrip: Frame
        /// A key and payload delivered independently to multiple subscribers.
        public let multipleSubscribers: Frame
        /// Accepted and overflow payloads for bounded receive-queue coverage.
        public let queueOverflow: QueueOverflow
        /// Bounds and fill byte for an oversized inbound key.
        public let keyOverflow: Overflow
        /// Bounds and fill byte for an oversized inbound payload.
        public let payloadOverflow: Overflow
        /// An unreachable endpoint used to exercise session-open failure.
        public let sessionFailure: SessionFailure
    }

    /// A key and byte-exact payload used by a conformance assertion.
    public struct Frame: Decodable {
        /// The key expression to publish or subscribe to.
        public let key: String
        /// The expected payload bytes, including non-UTF-8 values.
        public let payload: [UInt8]
    }

    /// The inputs and expected drop count for receive-queue saturation.
    public struct QueueOverflow: Decodable {
        /// The subscribed key expression.
        public let key: String
        /// Payloads admitted before the queue reaches capacity.
        public let acceptedPayloads: [[UInt8]]
        /// The payload expected to be rejected after capacity is reached.
        public let overflowPayload: [UInt8]
        /// The expected count of rejected newest frames.
        public let expectedDroppedFrameCount: UInt32
    }

    /// Size and byte values for testing the façade's inbound limits.
    public struct Overflow: Decodable {
        /// The key size used by the corresponding fixture, in bytes.
        public let keyLength: Int
        /// The payload size used by the corresponding fixture, in bytes.
        public let payloadLength: Int
        /// The repeated byte used to form the oversized input.
        public let fillByte: UInt8
    }

    /// The connection endpoint expected to fail during session opening.
    public struct SessionFailure: Decodable {
        /// An unreachable endpoint locator.
        public let endpoint: String
    }

    /// Errors raised while locating or decoding the bundled fixture.
    public enum FixtureError: Error {
        /// The fixture resource is not present in the target bundle.
        case resourceMissing
        /// The fixture cannot be decoded into the contract schema.
        case invalidDocument
    }
}
