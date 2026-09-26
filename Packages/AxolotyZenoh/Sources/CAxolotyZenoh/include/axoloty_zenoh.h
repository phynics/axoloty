// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

#ifndef AXOLOTY_ZENOH_H
#define AXOLOTY_ZENOH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result codes returned by every Axoloty Zenoh façade call.
///
/// The values are stable for programmatic handling. No Zenoh-owned
/// (`z_owned_*`) or Zenoh-loaned (`z_loaned_*`) type crosses this header; the
/// façade owns and destroys every Zenoh value internally.
typedef enum {
    /// The call completed successfully.
    AXOLOTY_ZENOH_OK = 0,
    /// A required argument was null, malformed, or out of range.
    AXOLOTY_ZENOH_INVALID_ARGUMENT = 1,
    /// The addressed session is not open.
    AXOLOTY_ZENOH_NOT_OPEN = 2,
    /// The façade's fixed session capacity is exhausted.
    AXOLOTY_ZENOH_CAPACITY_EXCEEDED = 3,
    /// Zenoh rejected the operation or the carrier failed.
    AXOLOTY_ZENOH_TRANSPORT_ERROR = 4,
    /// No complete frame is available to poll.
    AXOLOTY_ZENOH_QUEUE_EMPTY = 5,
    /// A frame could not be admitted because the receive queue is full.
    AXOLOTY_ZENOH_QUEUE_FULL = 6,
    /// An inbound key or payload exceeds its fixed receive bound.
    AXOLOTY_ZENOH_FRAME_TOO_LARGE = 7,
} axoloty_zenoh_result_t;

/// The lifecycle state of a session handle.
typedef enum {
    /// The handle addresses a closed session.
    AXOLOTY_ZENOH_SESSION_CLOSED = 0,
    /// The session is open.
    AXOLOTY_ZENOH_SESSION_OPEN = 1,
} axoloty_zenoh_session_state_t;

/// The connectivity mode a session opens in.
typedef enum {
    /// Connect to routers only. This is the v1 host profile (AD-7).
    AXOLOTY_ZENOH_MODE_CLIENT = 0,
    /// Peer mode, kept for the follow-up router-less milestone (#821).
    AXOLOTY_ZENOH_MODE_PEER = 1,
} axoloty_zenoh_mode_t;

/// The fixed number of sessions the façade can hold open at once.
///
/// The bound is a compile-time storage capacity, not a scheduling policy.
/// Opening a session while every slot is occupied returns
/// ``AXOLOTY_ZENOH_CAPACITY_EXCEEDED`` without partial mutation.
#define AXOLOTY_ZENOH_MAX_SESSIONS 4

/// The fixed number of independent subscriptions a session can hold.
///
/// Eight is a power of two, so three token bits identify a subscription slot
/// without division. The host needs two profile-interest subscriptions and
/// supports up to six simultaneous exact external routes.
#define AXOLOTY_ZENOH_MAX_SUBSCRIBERS 8

/// The largest connect endpoint the façade accepts, in bytes.
///
/// Endpoints are configuration, not Coaty routes, so this bound is independent
/// of the wire route bound.
#define AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES 512

/// The largest key expression the façade accepts, in bytes.
#define AXOLOTY_ZENOH_MAX_KEY_BYTES 256

/// The largest publication payload the façade accepts, in bytes.
#define AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES 2048

/// The fixed number of inbound frames held per subscription.
#define AXOLOTY_ZENOH_RECEIVE_QUEUE_CAPACITY 4

/// A bounded session configuration.
///
/// Every pointer is borrowed for the duration of ``axoloty_zenoh_open`` only.
/// The façade copies what it needs into its own Zenoh configuration before the
/// call returns and never retains a caller pointer.
typedef struct axoloty_zenoh_config_t {
    /// Connectivity mode for the new session.
    axoloty_zenoh_mode_t mode;
    /// Borrowed printable-ASCII connect endpoint bytes, or `NULL` for none.
    ///
    /// A client-mode session without an endpoint relies on Zenoh scouting.
    /// Endpoint bytes are validated before any Zenoh call: at most
    /// ``AXOLOTY_ZENOH_MAX_ENDPOINT_BYTES`` bytes, printable ASCII only, and
    /// neither `"` nor `\`, which the JSON5 configuration value cannot carry
    /// unescaped.
    const uint8_t *connect_endpoint;
    /// The number of valid bytes at ``connect_endpoint``.
    uint32_t connect_endpoint_length;
    /// Whether multicast scouting is enabled for this session.
    bool multicast_scouting_enabled;
} axoloty_zenoh_config_t;

/// An open Axoloty Zenoh session.
///
/// The type is opaque. Its representation, and every Zenoh-owned value inside
/// it, are private to the façade implementation.
///
/// The façade owns one fixed session registry per process and carries no
/// locks: session lifecycle calls are serialized by the caller (the host
/// runtime's single owner). The embedded backend has no threading machinery,
/// so thread safety is deliberately not a façade property.
typedef struct axoloty_zenoh_session axoloty_zenoh_session_t;

/// An opaque handle for one independently managed session subscription.
///
/// Handles are generation-guarded and must not be reused after unsubscribe or
/// session close. No Zenoh-owned or Zenoh-loaned type crosses this boundary.
typedef struct axoloty_zenoh_subscription axoloty_zenoh_subscription_t;

/// Opens a session from a bounded configuration.
///
/// The configuration and its endpoint bytes are borrowed only for this call.
/// On success ``out_session`` receives a handle that must be released with
/// ``axoloty_zenoh_close``. On every failure ``out_session`` is set to `NULL`
/// and all partially created state has already been released.
///
/// - Parameters:
///   - config: Borrowed configuration. Must not be `NULL`.
///   - out_session: Receives the open session handle. Must not be `NULL`.
/// - Returns: ``AXOLOTY_ZENOH_OK``; ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` when an
///   argument is null or the configuration is malformed;
///   ``AXOLOTY_ZENOH_CAPACITY_EXCEEDED`` when every session slot is occupied;
///   or ``AXOLOTY_ZENOH_TRANSPORT_ERROR`` when Zenoh cannot open the session.
axoloty_zenoh_result_t axoloty_zenoh_open(const axoloty_zenoh_config_t *config,
                                          axoloty_zenoh_session_t **out_session);

/// Closes a session and releases its Zenoh state.
///
/// A handle addresses an open session until the first successful close. A
/// repeated close of a handle whose slot is not open returns
/// ``AXOLOTY_ZENOH_NOT_OPEN`` and changes nothing. A reported close failure
/// still releases all façade state, so the handle is closed either way.
/// An active subscriber is disabled, undeclared, and drained before the
/// session is closed, using the same callback synchronization as
/// ``axoloty_zenoh_unsubscribe``.
///
/// Handles must not be retained or reused after close. Session slots are
/// reused by later opens, so a stale handle copied elsewhere is not
/// distinguishable from a current one; the Swift wrapper clears its handle on
/// close.
///
/// - Parameter session: A handle returned by ``axoloty_zenoh_open``. Must not
///   be `NULL`.
/// - Returns: ``AXOLOTY_ZENOH_OK`` when the session was open and is now
///   closed; ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` for a null or foreign handle;
///   ``AXOLOTY_ZENOH_NOT_OPEN`` for a handle that is already closed; or
///   ``AXOLOTY_ZENOH_TRANSPORT_ERROR`` when Zenoh reports a close failure.
axoloty_zenoh_result_t axoloty_zenoh_close(axoloty_zenoh_session_t *session);

/// Reads the lifecycle state of a session handle.
///
/// A handle whose slot has been closed still answers ``AXOLOTY_ZENOH_OK``
/// with ``AXOLOTY_ZENOH_SESSION_CLOSED``; only a null or foreign handle is
/// rejected.
///
/// - Parameters:
///   - session: A handle returned by ``axoloty_zenoh_open``. Must not be
///     `NULL`.
///   - out_state: Receives the state. Must not be `NULL`.
/// - Returns: ``AXOLOTY_ZENOH_OK`` when the state was read, or
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` for a null or foreign handle or a null
///   output pointer.
axoloty_zenoh_result_t axoloty_zenoh_state(const axoloty_zenoh_session_t *session,
                                           axoloty_zenoh_session_state_t *out_state);

/// Publishes one borrowed key and payload synchronously.
///
/// The key and payload are borrowed for this call only. The façade copies the
/// key into a Zenoh-owned key expression and copies the payload into a
/// Zenoh-owned byte value before calling Zenoh. Zenoh consumes that owned
/// payload before this function returns, so neither caller pointer is retained.
/// A zero-length payload is valid and may use a `NULL` payload pointer.
///
/// - Parameters:
///   - session: An open session returned by ``axoloty_zenoh_open``.
///   - key: Borrowed key-expression bytes. Must be non-null and non-empty.
///   - key_length: Number of valid key bytes, at most
///     ``AXOLOTY_ZENOH_MAX_KEY_BYTES``.
///   - payload: Borrowed payload bytes. May be `NULL` only when
///     `payload_length` is zero.
///   - payload_length: Number of valid payload bytes, at most
///     ``AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES``.
/// - Returns: ``AXOLOTY_ZENOH_OK`` when Zenoh accepts the publication;
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` for a null, malformed, or oversized
///   argument; ``AXOLOTY_ZENOH_NOT_OPEN`` for a closed session; or
///   ``AXOLOTY_ZENOH_TRANSPORT_ERROR`` when Zenoh rejects the publication or
///   cannot allocate its owned values.
axoloty_zenoh_result_t axoloty_zenoh_publish(const axoloty_zenoh_session_t *session,
                                             const uint8_t *key,
                                             uint32_t key_length,
                                             const uint8_t *payload,
                                             uint32_t payload_length);

/// Declares one subscriber with its own bounded queue.
///
/// Zenoh callback invocations are producers; ``axoloty_zenoh_poll`` is the
/// sole consumer. The queue uses atomic per-slot publication and position
/// claims, so concurrent callback invocations do not share write slots. It has
/// no locks. The caller must serialize subscribe, unsubscribe, poll, and
/// close; Zenoh may invoke callbacks on its own threads. A callback only copies
/// into façade-owned queue storage and never calls Swift or retains borrowed
/// Zenoh memory. Queue admission makes at most eight atomic-claim attempts; if
/// the queue is full or contention exhausts those attempts, the newest frame
/// is dropped and counted for that subscription. Oversized frames include
/// empty inbound keys and keys/payloads above the stated limits; they are
/// dropped, not truncated. A generation token rejects callbacks that arrive
/// after removal or slot reuse. Removal disables and undeclares the subscriber
/// without spinning for in-flight callbacks. Its handle becomes stale at once,
/// so its queued frames and counters are no longer accessible; the slot is
/// reused only after any callback already writing to it has returned. During
/// that brief retirement, subscribe may report capacity exceeded if no other
/// quiescent slot is free.
///
/// - Parameters:
///   - session: An open session.
///   - key: Borrowed canonical key expression bytes.
///   - key_length: Number of valid key bytes, from 1 through
///     ``AXOLOTY_ZENOH_MAX_KEY_BYTES``.
///   - out_subscription: Receives the opaque handle; set to `NULL` on failure.
/// - Returns: ``AXOLOTY_ZENOH_OK`` when declared;
///   ``AXOLOTY_ZENOH_CAPACITY_EXCEEDED`` when every slot is active or still
///   retiring from a callback, without changing an existing slot; invalid argument,
///   ``AXOLOTY_ZENOH_NOT_OPEN``, or transport error otherwise.
axoloty_zenoh_result_t axoloty_zenoh_subscribe(const axoloty_zenoh_session_t *session,
                                               const uint8_t *key,
                                               uint32_t key_length,
                                               axoloty_zenoh_subscription_t **out_subscription);

/// Removes exactly the addressed subscription. Closing a session removes all
/// its subscriptions.
/// The operation disables and undeclares the callback without waiting for
/// callbacks already running. The slot remains unavailable for reuse until any
/// in-flight callback has returned. It discards this subscription's queued
/// frames and pending poll notifications logically by making the handle stale.
/// A stale, foreign, or already removed subscription handle is rejected with
/// ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` and no mutation.
///
/// - Parameters:
///   - session: An open session.
///   - subscription: A live handle returned by ``axoloty_zenoh_subscribe``.
/// - Returns: ``AXOLOTY_ZENOH_OK`` when removed,
///   ``AXOLOTY_ZENOH_NOT_OPEN`` when the session is closed, or
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT`` for a null, stale, or foreign handle.
axoloty_zenoh_result_t axoloty_zenoh_unsubscribe(const axoloty_zenoh_session_t *session,
                                                 axoloty_zenoh_subscription_t *subscription);

/// Polls the oldest frame from one subscription into caller-owned buffers.
///
/// Both output buffers must hold the published key/payload lengths; set the
/// lengths output pointers to valid storage. Empty payloads are valid. A too-
/// small output buffer leaves the queued frame untouched and returns invalid
/// argument. A successful poll releases one queue slot, including after drops.
/// Once queued frames are drained, asynchronous full-queue and oversized-frame
/// drops are each reported once as ``AXOLOTY_ZENOH_QUEUE_FULL`` and
/// ``AXOLOTY_ZENOH_FRAME_TOO_LARGE`` respectively. Full-queue notifications
/// are returned first when both kinds are pending; both counters remain
/// cumulative for the lifetime of the subscription.
///
/// - Parameters:
///   - session: An open session.
///   - subscription: A live handle returned by ``axoloty_zenoh_subscribe``.
///   - key: Caller-owned key output buffer.
///   - key_capacity: Available key buffer bytes.
///   - out_key_length: Receives the copied key length.
///   - payload: Caller-owned payload output buffer.
///   - payload_capacity: Available payload buffer bytes.
///   - out_payload_length: Receives the copied payload length.
/// - Returns: ``AXOLOTY_ZENOH_OK`` with one frame,
///   ``AXOLOTY_ZENOH_QUEUE_EMPTY`` when no frame or drop notification is
///   pending, ``AXOLOTY_ZENOH_QUEUE_FULL`` or
///   ``AXOLOTY_ZENOH_FRAME_TOO_LARGE`` for a reported dropped frame, or an
///   argument or closed-session error.
axoloty_zenoh_result_t axoloty_zenoh_poll(const axoloty_zenoh_session_t *session,
                                          const axoloty_zenoh_subscription_t *subscription,
                                          uint8_t *key,
                                          uint32_t key_capacity,
                                          uint32_t *out_key_length,
                                          uint8_t *payload,
                                          uint32_t payload_capacity,
                                          uint32_t *out_payload_length);

/// Reads the number of currently queued frames (0 through queue capacity).
///
/// - Parameters:
///   - session: An open session.
///   - out_depth: Receives the current bounded queue depth.
/// - Returns: ``AXOLOTY_ZENOH_OK``, ``AXOLOTY_ZENOH_NOT_OPEN``, or
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT``.
axoloty_zenoh_result_t axoloty_zenoh_queue_depth(const axoloty_zenoh_session_t *session,
                                                 const axoloty_zenoh_subscription_t *subscription,
                                                 uint32_t *out_depth);

/// Reads the total number of newest frames dropped because the queue was full.
///
/// - Parameters:
///   - session: An open session.
///   - out_count: Receives the atomic dropped-frame count.
/// - Returns: ``AXOLOTY_ZENOH_OK``, ``AXOLOTY_ZENOH_NOT_OPEN``, or
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT``.
axoloty_zenoh_result_t axoloty_zenoh_dropped_frame_count(const axoloty_zenoh_session_t *session,
                                                         const axoloty_zenoh_subscription_t *subscription,
                                                         uint32_t *out_count);

/// Reads the total number of frames dropped because key or payload exceeded
/// ``AXOLOTY_ZENOH_MAX_KEY_BYTES`` or ``AXOLOTY_ZENOH_MAX_PAYLOAD_BYTES``.
///
/// - Parameters:
///   - session: An open session.
///   - out_count: Receives the atomic oversized-frame count.
/// - Returns: ``AXOLOTY_ZENOH_OK``, ``AXOLOTY_ZENOH_NOT_OPEN``, or
///   ``AXOLOTY_ZENOH_INVALID_ARGUMENT``.
axoloty_zenoh_result_t axoloty_zenoh_oversized_frame_count(const axoloty_zenoh_session_t *session,
                                                            const axoloty_zenoh_subscription_t *subscription,
                                                            uint32_t *out_count);

#ifdef __cplusplus
}
#endif

#endif /* AXOLOTY_ZENOH_H */
