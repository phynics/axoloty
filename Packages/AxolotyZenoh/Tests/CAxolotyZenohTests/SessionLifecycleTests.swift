// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

import CAxolotyZenoh

/// Ownership and lifecycle coverage for the C façade's session registry.
///
/// The suite is serialized because the façade owns one fixed session registry
/// for the process and does not lock it.
@Suite("Axoloty Zenoh C façade session lifecycle", .serialized)
struct CAxolotyZenohSessionLifecycleTests {
    private func baseConfiguration(
        mode: axoloty_zenoh_mode_t = AXOLOTY_ZENOH_MODE_PEER
    ) -> axoloty_zenoh_config_t {
        axoloty_zenoh_config_t(
            mode: mode,
            connect_endpoint: nil,
            connect_endpoint_length: 0,
            multicast_scouting_enabled: false
        )
    }

    /// Opens a session, copying the endpoint bytes only through the borrowed
    /// call, exactly as the façade contract permits.
    private func openSession(
        mode: axoloty_zenoh_mode_t = AXOLOTY_ZENOH_MODE_PEER,
        endpoint: [UInt8]? = nil
    ) -> (axoloty_zenoh_result_t, OpaquePointer?) {
        var session: OpaquePointer?
        var config = baseConfiguration(mode: mode)
        let result: axoloty_zenoh_result_t
        if let endpoint {
            result = endpoint.withUnsafeBufferPointer { buffer in
                config.connect_endpoint = buffer.baseAddress
                config.connect_endpoint_length = UInt32(buffer.count)
                return axoloty_zenoh_open(&config, &session)
            }
        } else {
            result = axoloty_zenoh_open(&config, &session)
        }
        return (result, session)
    }

    @Test("a peer session opens, reports OPEN, closes, and rejects a repeated close")
    func openStateClose() throws {
        let (openResult, opened) = openSession()
        #expect(openResult == AXOLOTY_ZENOH_OK)
        let session = try #require(opened)

        var state = AXOLOTY_ZENOH_SESSION_CLOSED
        #expect(axoloty_zenoh_state(session, &state) == AXOLOTY_ZENOH_OK)
        #expect(state == AXOLOTY_ZENOH_SESSION_OPEN)

        #expect(axoloty_zenoh_close(session) == AXOLOTY_ZENOH_OK)

        state = AXOLOTY_ZENOH_SESSION_OPEN
        #expect(axoloty_zenoh_state(session, &state) == AXOLOTY_ZENOH_OK)
        #expect(state == AXOLOTY_ZENOH_SESSION_CLOSED)

        #expect(axoloty_zenoh_close(session) == AXOLOTY_ZENOH_NOT_OPEN)
    }

    @Test("an unreachable client open fails and releases its slot")
    func unreachableClientCleansUp() throws {
        let endpoint = Array("tcp/127.0.0.1:1".utf8)
        let (failure, failedSession) = openSession(mode: AXOLOTY_ZENOH_MODE_CLIENT, endpoint: endpoint)
        #expect(failure == AXOLOTY_ZENOH_TRANSPORT_ERROR)
        #expect(failedSession == nil)

        // A malformed-but-well-formed locator fails inside Zenoh after the
        // config was built, covering the later partial-open cleanup stage.
        let (locatorFailure, locatorSession) = openSession(endpoint: Array("bogus-locator".utf8))
        #expect(locatorFailure == AXOLOTY_ZENOH_TRANSPORT_ERROR)
        #expect(locatorSession == nil)

        let (recovered, recoveredSession) = openSession()
        #expect(recovered == AXOLOTY_ZENOH_OK)
        let recoveredHandle = try #require(recoveredSession)
        #expect(axoloty_zenoh_close(recoveredHandle) == AXOLOTY_ZENOH_OK)
    }

    @Test("borrowed endpoint bytes are not retained after the open returns")
    func endpointBytesAreNotRetained() {
        var endpoint = Array("tcp/127.0.0.1:1".utf8)
        let (result, session) = openSession(mode: AXOLOTY_ZENOH_MODE_CLIENT, endpoint: endpoint)
        #expect(result == AXOLOTY_ZENOH_TRANSPORT_ERROR)
        #expect(session == nil)

        // Reusing the same buffer would expose a dangling borrow under ASan.
        for index in endpoint.indices {
            endpoint[index] = 0xFF
        }
        let (second, secondSession) = openSession(mode: AXOLOTY_ZENOH_MODE_CLIENT, endpoint: endpoint)
        #expect(second == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(secondSession == nil)
    }

    @Test("session capacity saturates without partial mutation and releases on close")
    func capacitySaturationAndRelease() throws {
        var sessions: [OpaquePointer] = []
        for _ in 0..<Int(AXOLOTY_ZENOH_MAX_SESSIONS) {
            let (result, opened) = openSession()
            #expect(result == AXOLOTY_ZENOH_OK)
            sessions.append(try #require(opened))
        }

        let (overflow, overflowSession) = openSession()
        #expect(overflow == AXOLOTY_ZENOH_CAPACITY_EXCEEDED)
        #expect(overflowSession == nil)

        let released = sessions.removeFirst()
        #expect(axoloty_zenoh_close(released) == AXOLOTY_ZENOH_OK)
        #expect(axoloty_zenoh_close(released) == AXOLOTY_ZENOH_NOT_OPEN)

        let (reopened, reopenedSession) = openSession()
        #expect(reopened == AXOLOTY_ZENOH_OK)
        let reopenedHandle = try #require(reopenedSession)
        #expect(axoloty_zenoh_close(reopenedHandle) == AXOLOTY_ZENOH_OK)

        for session in sessions {
            #expect(axoloty_zenoh_close(session) == AXOLOTY_ZENOH_OK)
        }
    }

    @Test("malformed arguments are rejected before any Zenoh access")
    func malformedArguments() {
        var session: OpaquePointer?
        var config = baseConfiguration()

        #expect(axoloty_zenoh_open(nil, &session) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(session == nil)
        #expect(axoloty_zenoh_open(&config, nil) == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        var badMode = config
        badMode.mode = axoloty_zenoh_mode_t(rawValue: 99)
        #expect(axoloty_zenoh_open(&badMode, &session) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(session == nil)

        var nullEndpoint = config
        nullEndpoint.connect_endpoint = nil
        nullEndpoint.connect_endpoint_length = 4
        #expect(axoloty_zenoh_open(&nullEndpoint, &session) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(session == nil)

        var oversize = config
        let tiny: [UInt8] = [0x61]
        tiny.withUnsafeBufferPointer { buffer in
            oversize.connect_endpoint = buffer.baseAddress
            oversize.connect_endpoint_length = UInt32(AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES + 1)
            #expect(axoloty_zenoh_open(&oversize, &session) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        }
        #expect(session == nil)

        for rejected in [Array("\"".utf8), Array("\\".utf8), [0x01], [0x20], [0x7F]] {
            let (result, rejectedSession) = openSession(endpoint: rejected)
            #expect(result == AXOLOTY_ZENOH_INVALID_ARGUMENT)
            #expect(rejectedSession == nil)
        }
    }

    @Test("null and foreign handles are rejected without dereference")
    func nullAndForeignHandles() throws {
        var state = AXOLOTY_ZENOH_SESSION_CLOSED
        #expect(axoloty_zenoh_close(nil) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(axoloty_zenoh_state(nil, &state) == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        let foreign = OpaquePointer(bitPattern: 0xDEAD_BEEF)!
        #expect(axoloty_zenoh_close(foreign) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(axoloty_zenoh_state(foreign, &state) == AXOLOTY_ZENOH_INVALID_ARGUMENT)

        let (openResult, opened) = openSession()
        #expect(openResult == AXOLOTY_ZENOH_OK)
        let session = try #require(opened)
        #expect(axoloty_zenoh_state(session, nil) == AXOLOTY_ZENOH_INVALID_ARGUMENT)
        #expect(axoloty_zenoh_close(session) == AXOLOTY_ZENOH_OK)
    }
}