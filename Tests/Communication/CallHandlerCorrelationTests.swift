// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

@testable import Axoloty
import Foundation
import Testing

/// Regression coverage for Call correlation reservation around payload
/// validation. These tests use the in-memory communication client seam and do
/// not require a broker.
@MainActor
@Suite
struct CallHandlerCorrelationTests {

    @Test
    func malformedParametersDuplicateIsSuppressed() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let invocations = CallInvocationStore()
        let registration = try await manager.registerCallHandler(operation: "malformed-parameters") { request in
            await invocations.increment()
            return .success(result: request.parameters ?? "null")
        }
        defer { registration.cancel() }

        try await assertMalformedDuplicate(
            on: client,
            malformed: CallEventSnapshot(
                correlationId: "malformed-parameters-duplicate",
                operation: "malformed-parameters",
                parameters: "{"
            ),
            validCorrelationId: "malformed-parameters-valid",
            invocations: invocations,
            expectedMessage: "Malformed Call parameters"
        )
    }

    @Test
    func malformedFilterDuplicateIsSuppressed() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let invocations = CallInvocationStore()
        let registration = try await manager.registerCallHandler(operation: "malformed-filter") { _ in
            await invocations.increment()
            return .success(result: "true")
        }
        defer { registration.cancel() }

        try await assertMalformedDuplicate(
            on: client,
            malformed: CallEventSnapshot(
                correlationId: "malformed-filter-duplicate",
                operation: "malformed-filter",
                filter: "{"
            ),
            validCorrelationId: "malformed-filter-valid",
            invocations: invocations,
            expectedMessage: "Malformed context filter"
        )
    }

    @Test
    func malformedDuplicateIsReprocessedAfterDeterministicExpiry() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let clock = DeterministicCallHandlerClock()
        let invocations = CallInvocationStore()
        let registration = try await manager.registerCallHandler(
            operation: "malformed-expiry",
            deduplicationWindow: .seconds(10),
            now: { clock.now }
        ) { _ in
            await invocations.increment()
            return .success(result: "true")
        }
        defer { registration.cancel() }

        let malformed = CallEventSnapshot(
            correlationId: "malformed-expiry-correlation",
            operation: "malformed-expiry",
            parameters: "{"
        )
        await client.emitCall(malformed, operation: malformed.operation)
        _ = try await waitForReturnPublication(on: client)

        let readsAfterFirstCompletion = clock.readCount
        await client.emitCall(malformed, operation: malformed.operation)
        try await waitUntil("malformed duplicate reservation") {
            clock.readCount > readsAfterFirstCompletion
        }
        #expect(returnPublications(on: client).count == 1)

        clock.advance(by: .seconds(11))
        await client.emitCall(malformed, operation: malformed.operation)
        _ = try await waitForReturnPublication(on: client, count: 2)

        #expect(await invocations.count == 0)
        #expect(returnPublications(on: client).count == 2)
    }

    @Test
    func malformedCorrelationBeyondLegacyCapRemainsSuppressedUntilExpiry() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let clock = DeterministicCallHandlerClock()
        let invocations = CallInvocationStore()
        let registration = try await manager.registerCallHandler(
            operation: "malformed-cap",
            deduplicationWindow: .seconds(5),
            now: { clock.now }
        ) { _ in
            await invocations.increment()
            return .success(result: "true")
        }
        defer { registration.cancel() }

        let distinctCorrelationCount = 1_025
        let firstMalformed = CallEventSnapshot(
            correlationId: "malformed-cap-0",
            operation: "malformed-cap",
            parameters: "{"
        )
        for index in 0 ..< distinctCorrelationCount {
            await client.emitCall(
                index == 0
                    ? firstMalformed
                    : CallEventSnapshot(
                        correlationId: "malformed-cap-\(index)",
                        operation: "malformed-cap",
                        parameters: "{"
                    ),
                operation: "malformed-cap"
            )
        }
        try await waitUntil("distinct malformed Calls completed") {
            returnPublications(on: client).count == distinctCorrelationCount
        }

        let readsAfterDistinctCompletions = clock.readCount
        await client.emitCall(firstMalformed, operation: "malformed-cap")
        try await waitUntil("first malformed duplicate reservation") {
            clock.readCount > readsAfterDistinctCompletions
        }
        #expect(returnPublications(on: client).count == distinctCorrelationCount)

        clock.advance(by: .seconds(6))
        await client.emitCall(firstMalformed, operation: "malformed-cap")
        try await waitUntil("expired first malformed Call reprocessing") {
            returnPublications(on: client).count == distinctCorrelationCount + 1
        }

        #expect(await invocations.count == 0)
    }

    @Test
    func contextMismatchDoesNotConsumeCorrelation() async throws {
        let client = FakeCommunicationClient(delegate: FakeStartable())
        let manager = makeManager(client: client)
        try await bringOnline(manager, client: client)
        let invocations = CallInvocationStore()
        let registration = try await manager.registerCallHandler(
            operation: "context-reuse",
            context: manager.identity
        ) { _ in
            await invocations.increment()
            return .success(result: "true")
        }
        defer { registration.cancel() }

        let nonmatchingFilter = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals("someone-else")
        ))
        let matchingFilter = ObjectFilter(condition: ObjectFilterCondition(
            property: ObjectFilterProperty("name"),
            expression: .equals(FilterOperand(manager.identity.name))
        ))
        let nonmatchingData = try JSONEncoder().encode(nonmatchingFilter)
        let matchingData = try JSONEncoder().encode(matchingFilter)
        let correlationId = "context-reuse-correlation"
        let nonmatchingFilterJSON = try #require(String(bytes: nonmatchingData, encoding: .utf8))
        let matchingFilterJSON = try #require(String(bytes: matchingData, encoding: .utf8))

        await client.emitCall(
            CallEventSnapshot(
                correlationId: correlationId,
                operation: "context-reuse",
                filter: nonmatchingFilterJSON
            ),
            operation: "context-reuse"
        )
        await client.emitCall(
            CallEventSnapshot(
                correlationId: correlationId,
                operation: "context-reuse",
                filter: matchingFilterJSON
            ),
            operation: "context-reuse"
        )

        try await waitUntil("matching Call after context mismatch") {
            returnPublications(on: client).contains {
                topicCorrelationId($0.topic) == correlationId
            }
        }
        #expect(await invocations.count == 1)
        #expect(returnPublications(on: client).count == 1)
    }
}

@MainActor
private func assertMalformedDuplicate(
    on client: FakeCommunicationClient,
    malformed: CallEventSnapshot,
    validCorrelationId: String,
    invocations: CallInvocationStore,
    expectedMessage: String
) async throws {
    await client.emitCall(malformed, operation: malformed.operation)
    _ = try await waitForReturnPublication(on: client)

    await client.emitCall(malformed, operation: malformed.operation)
    await client.emitCall(
        CallEventSnapshot(correlationId: validCorrelationId, operation: malformed.operation),
        operation: malformed.operation
    )
    try await waitUntil("valid Call Return after malformed duplicate") {
        returnPublications(on: client).contains {
            topicCorrelationId($0.topic) == validCorrelationId
        }
    }

    #expect(returnPublications(on: client).count == 2)
    #expect(await invocations.count == 1)
    let malformedCorrelationId = try #require(malformed.correlationId)
    let malformedPublication = try #require(
        returnPublications(on: client).first {
            topicCorrelationId($0.topic) == malformedCorrelationId
        }
    )
    let malformedEvent = try JSONDecoder().decode(
        ReturnEvent.self,
        from: Data(malformedPublication.message.utf8)
    )
    #expect(malformedEvent.data.error?.code == -32602)
    #expect(malformedEvent.data.error?.message == expectedMessage)
}

private actor CallInvocationStore {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
private final class DeterministicCallHandlerClock {
    private var current = ContinuousClock().now
    private(set) var readCount = 0

    var now: ContinuousClock.Instant {
        readCount += 1
        return current
    }

    func advance(by duration: Duration) {
        current = current.advanced(by: duration)
    }
}
