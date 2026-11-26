---
status: accepted
---

# Soft-state presence for `axoloty/1`

Accepted for [#1060](https://github.com/phynics/axoloty/issues/1060) on
2026-11-26, with the amendments recorded below. The original draft resolved the
six decisions the issue lists and added a seventh (transport reset). The owner
accepted the additive wire fields, the owner-epoch refresh signal, longer lease,
reset suspension, CBOR-only corpus, and additive expiry reporting. Implementation
follows this document.

## Context

MQTT peers learn of an unclean disconnect through the broker-published last
will. Zenoh has no equivalent in the v1 client profile:
[`docs/transports/zenoh.md`](../transports/zenoh.md) states that
`ZenohBinding` discards the will and that after an unclean disconnect "peers
receive no Deadvertise for the lost node". Epic
[#796](https://github.com/phynics/axoloty/issues/796) keeps Zenoh liveliness out
of v1 scope. [ADR 0009](./0009-zenoh-carries-only-axoloty-1.md) puts Zenoh on
`axoloty/1` only, so any fix lives in `axoloty/1` and `coaty/3` stays sealed
([ADR 0002](./0002-seal-coaty-core-profile-3.md)).

The device-side motivation is in
[phynics/axoloty-embedded#56](https://github.com/phynics/axoloty-embedded/issues/56)
(two-party Swift-over-Zenoh qualification) and
[#107](https://github.com/phynics/axoloty-embedded/issues/107) (recovery under
load and loss; its findings 3 and 4 say a stall can expire the session and that
"peers cannot tell a crash from silence").

### Evidence labels

Every figure in this ADR carries one label.

- **measured**: produced by code run for this ADR, with the command below.
- **derived**: arithmetic from stated assumptions or from reading source.
- **assumed**: a planning value nobody has measured.
- **issue**: quoted from #1060 or its linked issues; not reproducible here.

### The issue's processor claims, tested

The issue says its processor findings are "from reading the code; not tested".
All three were tested. **None of the three claims was wrong.** The evidence is a
throwaway Swift Testing file, `ZZThrowawayPresenceEvidenceTests.swift`, added
under `Packages/AxolotyProtocol/Tests/AxolotyProtocolTests/` for the run and
deleted before commit. Command (pinned `axoloty-dev` image, run directly in
Podman; see [Verification performed](#verification-performed) for why not
`make test-one`):

```text
swift test --package-path Packages/AxolotyProtocol --scratch-path .build/adr1060 --filter ZZThrowaway
```

Result at `d3327940` (Core 1.0.1): `Test run with 4 tests in 1 suite passed`
(4 tests, 7 cases: each protocol test ran under both `coaty/3` JSON and
`axoloty/1` CBOR). The same file run against the `v0.10.0` sources, the release
that shipped `axoloty/1` (extracted with `git archive v0.10.0 Packages`, same
command): `Test run with 4 tests in 1 suite passed`, with the same results for
all three claims. The one difference is the Deadvertise from a non-owning
source: `v0.10.0` rejects it as `malformedFrame`, current code accepts it and
removes nothing. Either way it frees no slot.

**Claim 1: a lost peer's entry holds its slot and can saturate the table.
Confirmed (measured).** A `ProtocolProcessor<4>` received four peers' Advertise
frames (`activeObjects=4`). With no further traffic, `expire(nowMS: 600000)`
(ten minutes later) returned `false` and `activeObjects` stayed `4`: `expire`
at `ProtocolProcessor.swift:196` walks only pending request correlations, never
objects. A fifth peer's Advertise was `rejected(capacityExceeded)` and
delivered nothing (`ProtocolProcessor.swift`, object planning). A Deadvertise from a
different source was `accepted` (at `v0.10.0`: `rejected(malformedFrame)`) but
removed nothing, because an inbound
Deadvertise removes only entries its own source owns
(`markDeadvertisedObjects`). The owning source's Deadvertise freed
exactly one slot and the fifth peer then fit. `resetTransport()` (`:226`)
discarded all four. Identical under both profiles. So only a Deadvertise from
the owner or a local transport reset ever frees a lost peer's slot.

**Claim 2: a repeated Advertise for the same source and object is rejected as
`.duplicate`. Confirmed (measured), and stronger than the issue states.**
`planObjectTransition` returns `.rejected(.duplicate)` at
`ProtocolProcessor.swift`, object planning, for any active entry with the same `sourceID` and
`objectID` unless it is a local, not-yet-announced replay. In the run the
identical repeat, a repeat with a changed `name`, and a repeat carrying an extra
envelope field were all `rejected(duplicate)` with zero deliveries, and
`generation` did not move (`1 -> 1`), so the rejection is atomic. A refresh
therefore refreshes nothing today, and neither does a changed object: a
re-Advertise cannot update a held entry.

**Claim 3: an older decoder ignores an unknown Advertise envelope field.
Confirmed (measured) for `v0.10.0` and for the code before this ADR's wire fields.** `AdvertiseWireData(from:)` reads `object` and `privateData` only
(`WireDTOs.swift:80`). With an extra `leaseMs` field next to `object`,
`AdvertiseWireData` returned byte-identical `object` bytes and a `nil`
`privateData`, and the processor returned `accepted` with one delivery, under
both profiles. The extra field cost 11 bytes in CBOR (37 B to 48 B) and 16 in
JSON (62 B to 78 B) (measured). The Advertise path is unchanged between
`v0.10.0` and `v1.0.1` (`git diff v0.10.0 v1.0.1` on `ProtocolProcessor.swift`
touches only the Deadvertise path and an import).

### The N²·M estimate and the "about 12 devices" crossover, re-derived

The N² scaling is correct (derived). The "about 12 devices" figure cannot be
reproduced from what the issue states, because it names no reference design.
Details follow.

Assumptions (assumed): N devices on one Zenoh fabric, each advertising M
objects, each refreshing every R seconds; every device subscribes to the
Advertise route and receives every other device's refresh; no loss.

```text
publishes per second, whole fabric        P = N·M / R
receives per second at one device         r = (N−1)·M / R
deliveries per second, whole fabric       D = N·(N−1)·M / R  ≈ N²·M / R
```

With R = 10 s (derived):

| N | M=1 r (/s) | M=1 D (/s) | M=2 r (/s) | M=2 D (/s) | M=4 r (/s) | M=4 D (/s) |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 0.30 | 1.2 | 0.60 | 2.4 | 1.20 | 4.8 |
| 8 | 0.70 | 5.6 | 1.40 | 11.2 | 2.80 | 22.4 |
| 12 | 1.10 | 13.2 | 2.20 | 26.4 | 4.40 | 52.8 |
| 16 | 1.50 | 24.0 | 3.00 | 48.0 | 6.00 | 96.0 |
| 32 | 3.10 | 99.2 | 6.20 | 198.4 | 12.40 | 396.8 |
| 64 | 6.30 | 403.2 | 12.60 | 806.4 | 25.20 | 1612.8 |

A crossover needs a reference design. Against a reference that costs a device
ρ messages per second to receive, soft-state is cheaper while
`(N−1)·M/R < ρ`, so the crossover is `N* = 1 + ρ·R/M` (derived). The issue's 12
falls out only for **ρ = 1.1 /s with M = 1 and R = 10 s**, that is, a reference
of roughly one message per second per device. The issue does not say what its
"heartbeat-based design" sends. Other plausible references move the number a
lot (derived): ρ = 0.4 /s (one message every 2.5 s) gives N* = 5; ρ = 1 /s gives
11; ρ = 2 /s gives 21; and at M = 2 or M = 4 each of these halves or quarters.
Two further points:

- A pub/sub heartbeat is also N² in aggregate (every device receives every other
  device's heartbeat). Only a router-assisted mechanism such as Zenoh liveliness
  is linear in N. So the real comparison is soft-state against liveliness,
  which #796 excludes from v1. Liveliness cost was not measured.
- On a device the binding is bounded before traffic is. The profile table holds
  `ProtocolBufferConfig.Preset.esp32C6Static = 16` objects in total
  (`ProtocolBufferConfig.swift:20`), local objects included, and the binding's
  receive queue holds four frames per subscription
  ([`zenoh.md`](../transports/zenoh.md)). Decision 6 uses those two bounds.

## Decision

### 1. Where the lease lives

**Options.**

- **A. Optional top-level fields on the Advertise envelope**, next to `object`
  and `privateData`.
- B. A field inside the advertised `object`.
- C. A new event code (for example a presence event) beside Advertise.
- D. A new profile, `axoloty/2`.

**Accepted: A**, with two optional fields, both `axoloty/1` only:

```cddl
advertise = {
  "object": object,
  ? "privateData": any,
  ? "leaseMs": uint,       ; presence lease the owner promises to refresh within
  ? "ownerEpoch": uint,    ; per-process incarnation; changes on every start
}
```

**Reason.** The field is protocol metadata about the announcement, not
application data, so it belongs in the envelope. Measured: current and
`v0.10.0` decoders ignore an unknown envelope field and still deliver the
Advertise (Claim 3). B puts protocol state inside an application object, where
shipped handlers would see it and a user schema could collide with the name. C
adds a fourteenth member to the closed capability inventory, may need a
subscriber slot beyond the two of eight the Zenoh façade reserves, and still
needs a full Advertise to introduce an object. D partitions the fleet. A route
prefix is the authoritative profile signal, ADR 0009 allows exactly one profile
per binding, and a node on `axoloty/2` could not hear a shipped `axoloty/1`
device at all.

`ownerEpoch` replaces the draft's `isRefresh` flag. A frame cannot prove whether
it is the last one an owner sends: a lost announce followed by refreshes would
keep a reboot masked. A per-process epoch is carried on every leased
Advertise, so any later frame reveals a restart. It costs four bytes per slot
and about the same on the wire.

**Bounds.** `leaseMs` is accepted in 1,000 to 3,600,000 (one hour).
`ownerEpoch` is accepted in 1 to 2,147,483,647. Both fields are present
together or absent together; one without the other, a non-integer or
out-of-range value, or a zero lease is a structured `malformedPayload`
rejection with no state change when presence is on. The upper lease bound keeps
a lease inside the signed 32-bit window of the processor's wrapping time
comparison (`ProtocolProcessor.swift`, about 24.8 days; derived). The new
decoder may be strict because only new senders produce these fields.

**Opt-in is a processor policy, not an encoding conditional.** Presence
handling is off by default. A processor constructed as today ignores both
fields and behaves exactly as it does now, so `coaty/3` bindings and every
shipped composition are byte- and behaviour-identical. An `axoloty/1` binding
that wants presence passes a presence policy at construction, in the same way
it passes `ProtocolCapabilities`. Bounds on the fields apply only when the
policy is on. Decoding itself never throws for these fields; the policy path
validates them, so a presence-off or `coaty/3` receiver keeps accepting frames
it accepts today.

A presence policy on a `coaty/3` codec is a construction error: `coaty/3` stays
sealed and a `coaty/3` Advertise carrying the fields is stored and delivered
exactly like one without them and never expires.

**What would change this.** If a future field needs to be mandatory, that is
`axoloty/2`. If reordering is measured to be harmful beyond the bounded ghost
window, a separate ordered field is needed.

### 2. Refresh semantics versus duplicates

**Options.**

- A. Every repeat of a held (source, object) is a silent renew.
- B. Compare a stored digest of the object bytes: renew silently if equal,
  deliver if different.
- **C. The owner epoch** on the Advertise identifies the incarnation.

**Accepted: an owner epoch**, replacing the draft's owner-declared refresh
flag. For an inbound Advertise whose (source, object) matches a held entry:

| Inbound Advertise | Held entry | Result |
|---|---|---|
| same `ownerEpoch`, lease present | present | Renew `lastSeen` and the declared lease, deliver nothing, no state-generation change. |
| different `ownerEpoch`, lease present | present | Re-announce: replace, renew, deliver, and release the rows naming the object. A restarted owner is seen even if the object bytes are identical. |
| lease present | absent | Announce: insert and deliver. A late joiner is healed within one refresh interval. |
| no lease | present leased entry | Re-announce without a lease: replace, deliver, clear the lease, and release rows. A firmware rollback is visible and never expires. |
| no lease | present unleased entry | Unchanged: `rejected(duplicate)`. |
| no lease | absent | Unchanged: insert and deliver, no lease, never expires. |
| lease present | present local entry | Unchanged: `rejected(duplicate)`. The owner's own echo never refreshes itself. |

A refresh carries the complete object, not a stub, so the absent rows deliver a
real object, including to a shipped late joiner. The owner must therefore retain
the object bytes (the host runtime does; the static runtime's caller does). The
processor still stores no payload.

**Reason.** The draft's `isRefresh` flag could not distinguish a lost announce
from a periodic refresh; one dropped announce hid a reboot until the next
announce. An epoch is carried on every leased Advertise, so any later frame
reveals the restart, and the owner can retransmit identical bytes. The receiver
needs no digest. A changed object under the same epoch is an owner bug; the
renew wins and the stale content is not delivered. An owner that lies about its
epoch can still hide a restart; the wire cannot prove otherwise.

**Outcome signalling.** A renewed entry is `.accepted` with no delivery action.
The outcome enum is unchanged; the host and static runtimes already tolerate an
accepted inbound frame with zero actions.

**Associate rows.** A re-announce releases the rows naming the object, the same
way a Deadvertise does, and reports them against the Advertise frame. IO routing
re-issues its intents for the endpoint, so a device that reboots inside its
lease does not lose IO. A pure renew changes no rows.

**What would change this.** If owners cannot provide a stable per-process
epoch, fall back to a digest and accept the masked restart.

### 3. Lease value and miss tolerance

**Options.** Refresh interval R and declared lease L, `L = k·R`.

- A. R = 10 s, L = 30 s (the issue's starting point).
- **B. R = 10 s, L = 45 s.**
- C. A larger R (30 s or more) for large fabrics.

**Accepted: B as the documented default; the owner declares L, so the
default is advice, not wire policy.**

**Reason (derived).** The peer's removal time is `lastSeen + L`, and a refresh
that arrives exactly at that boundary races the expiry check. A lease of `k·R`
therefore tolerates `k − 1` consecutive lost refreshes, not `k`. The issue's
"3 missed refreshes, about 30 s" is `L = 3R` and tolerates 2. Tolerating 3
needs `L > 3R`; 45 s gives half a period of margin, so the fourth refresh at
40 s stays inside the lease. Detection after a crash falls in `[L − R, L]` after
the crash, plus the caller's expiry polling interval: 35 to 45 s. Consecutive-loss arithmetic with an independent per-frame
loss probability p (assumed; #107 plans a 1 to 10 % sweep and has not produced
a number):

| p | A needs 3 losses | mean time to one false expiry per observed pair | B needs 4 losses | mean time per pair |
|---:|---:|---:|---:|---:|
| 1 % | 1.0e-6 | 2,778 h | 1.0e-8 | 277,778 h |
| 5 % | 1.25e-4 | 22 h | 6.25e-6 | 444 h |
| 10 % | 1.0e-3 | 2.8 h | 1.0e-4 | 27.8 h |

A false expiry is not a failure of correctness: the next refresh arrives for an
absent entry, is treated as an announce, and the object returns within R. A
false expiry does not release Associate rows, so a transient loss does not
become a permanent IO outage. Losses are not independent in practice (a 4 s Wi-Fi drop,
from the issue and not reproducible here, costs at most one refresh at R =
10 s; a longer outage costs several), so the table is an upper bound on
comfort, not a prediction.

**What would change this.** Measured loss under `DROP` congestion control from
#107, the measured reconnect distribution, or a power budget that cannot afford
R = 10 s. Raise R (option C) and keep `L = 4.5R`. The receiver clamps nothing
inside 1 s to 1 h; it trusts the owner.

### 4. Who drives refresh

**Options.**

- A. Application-driven: the application calls refresh.
- **B. Runtime-driven on the host; caller-driven on the static runtime.**
- C. Both, with an application keepalive gate on the host.

**Accepted: B**, and the processor stays passive. `AxolotyProtocol` gains pure
functions of caller-supplied time: which local entries are due for a refresh
(reported to the caller), and a peer-expiry pass over held entries. It owns no
timer, task, or clock. The host `AxolotyRuntime` owns one bounded refresh timer,
new work in `Source/Runtime`. On the static runtime the caller already owns the
loop and calls the same functions with its monotonic milliseconds, the contract
`expire(nowMS:)` already follows.

**Reason.** The host cannot ask every application to remember a timer. On a
device the refresh runs in the same loop that runs the application, so a hung
loop stops refreshing without extra machinery, which is the "hung application,
live transport" case the issue wants. On the host, a runtime-driven timer keeps
refreshing for a wedged application, so the host does not detect that case.

Refresh phase is anchored to the owner's local clock and is never restarted by
a reconnect; otherwise a router restart re-synchronizes every owner into
periodic N·M bursts. The first offset after boot is derived deterministically
from the source identifier (no random source in the portable core), and a
post-reconnect re-announce uses the same jitter. The host runtime retains the
local Advertise bytes it needs to refresh; the static runtime's caller retains
them. A lease declaration must fit the configured payload capacity both as an
announce and as a refresh, because deterministic key order re-encodes the map.

The host timer is one runtime-owned task over a time-parameterized processor
function. It is cancelled and awaited before the graceful Deadvertise, is
epoch-checked like the reconnect path (#1076), and does not refresh while
reconnecting, where the publication would queue in offline work. The host
passes its own monotonic clock to both inbound presence stamping and expiry, so
there is one clock; the transport's frame timestamp is not used for presence.

**What would change this.** Owners who need host hang detection should get option
C: an optional runtime setting under which refresh continues only while the
application has signalled liveness within an interval. That is more public
surface; defer it until someone asks.

### 5. Late Deadvertise and resurrection

Two races, treated differently.

**Refresh behind a Deadvertise (resurrection).** The owner publishes a refresh,
then a graceful Deadvertise. They travel on different keys
(`ADV` and `DAD`). This ADR assumes, unverified, that Zenoh gives no
ordering guarantee across different key expressions, and a `DROP` publish can
also be lost, so the refresh can arrive second and re-insert a ghost, via
decision 2 row 2.

- Options: (a) owner generation or sequence number on every Advertise and
  Deadvertise; (b) a bounded tombstone table of recently removed
  (source, object) pairs; (c) accept the window.
- **Accepted: (c), plus an owner rule.** The ghost is bounded by the
  lease: it expires in at most L (45 s by default) and the failure is
  self-healing, which is the point of soft state. The owner rule is: stop the
  refresh timer before publishing Deadvertise, and never refresh after it, so
  only frames already in flight can race.
- Rejected: (a) adds a second field to Deadvertise, whose shape is shared with
  `coaty/3` and CoatyJS; (b) adds a second fixed table that saturates
  independently and needs its own expiry.
- **What would change this.** A requirement that a gracefully stopped device is
  never visible again, or measured reordering, would justify (a) as a separate
  `axoloty/1` field.

**Refresh after expiry.** The owner is alive but its refreshes were delayed. The
entry was removed; the next refresh is an announce for an absent entry and is
delivered. That is the intended recovery and needs nothing more.

**Expiry is its own local event.** Expiry removes the object entry and reports
the removed `(sourceID, objectID)` to the caller. It never fabricates a wire
Deadvertise, and nothing is published. Per entry, the removal and its report
commit together: the pass returns one expired identifier per call, so work is
bounded and there is no sink-saturation path. A false expiry must not become a
permanent IO outage, so expiry **does not release Associate rows**. Rows are
released by wire signals (Deadvertise, a re-announce, a router disassociation)
and by a local transport reset. IO routing consumes the expiry report and
locally disassociates the endpoint; the processor rows that remain when no
router signal arrives are a documented leak, bounded by a later Deadvertise or
reset.

**Decision 8: expiry reporting.** The frozen public enums
(`BorrowedProtocolAction`, `OwnedProtocolAction`, `RuntimePresenceEvidence`)
gain no cases. The processor exposes a time-parameterized expiry pass returning
identifiers only. The host runtime exposes one additive bounded expiry stream
of an additive value struct and stores no payload. The static runtime exposes
the same pass to its caller. This keeps presence in a minor release; a later
major may fold the report into the action and evidence enums.

### 6. Scale and supported device count

The supported count is the smaller of a table bound and a traffic bound.

**Table bound (derived).** The table holds C objects including the device's own.
With M objects per device, one extra incarnation of headroom for a device
that restarts under a new source identity and leaves a stale entry until its
lease runs out, `N ≤ ⌊C / M⌋ − 1`:

| Profile | C | M = 1 | M = 2 | M = 4 |
|---|---:|---:|---:|---:|
| `esp32C6Static` | 16 | 15 | 7 | 3 |
| `hostDefault` | 64 | 63 | 31 | 15 |

**Traffic bound.** Per-device receive rate is `r = (N−1)·M/R` (table above).
The binding bounds are four queued frames per subscription and 2,048-byte
payloads; the device cost per frame and the drop rate at a given r are
unmeasured. A refresh frame is taken to be on the order of 200 bytes (assumed), so
r = 1.1 /s at N = 12, M = 1 is about 220 B/s, a small bandwidth that still wakes
the radio and the receive path about once a second. Whether that is acceptable
is a power and queue question that needs device evidence.

**Accepted.** State a design target, not a guarantee: **up to 7 devices
with up to 2 advertised objects each on `esp32C6Static`** (14 of 16 slots, one
incarnation of headroom), and up to 31 on `hostDefault` at the same M. Do not
state 12. Raise the claim only after the embedded repository measures drops and
heap at the target r. Beyond the table bound the answer is not "tune R", it is a
larger capacity preset or a different mechanism.

**What would change this.** Measured per-frame cost and drop rate; adopting
liveliness, which is linear in N (reference design for a future ADR); a
refresh interval that adapts to fabric size, which needs the owner to learn N
and is out of scope here.

### 7. Transport reset (not in the issue's list)

Today `resetTransport()` discards every peer-only entry and keeps local ones
replayable (`ProtocolProcessor.swift:226`); the host runtime calls it on
reconnect (`AxolotyRuntime.swift`, reconnect and ingress-pump paths) and reports
`RuntimePresenceEvidence.transportReset`. With that behaviour a 4 s reconnect (the issue's figure for a forced
Wi-Fi drop; not reproducible here), long enough to pass the binding's
one-second loss debounce, drops every peer
and holds them out until their next refresh. That conflicts with the acceptance
item "a short reconnect inside the lease causes no departure".

**Accepted.** With presence on, transport loss does not immediately discard
leased peer entries. A new `suspendPresence()` call marks presence suspended,
retains leased peers and local entries, and discards unleased peers as today.
It does not re-base their `lastSeen`; the failure and the recovery are different
edges. A later `resumePresence(nowMS:)` (the transport-ready call) re-bases every
retained leased peer's `lastSeen` to that time and clears the suspension.
Repeated suspends and resumes are idempotent. Expiry is suppressed while
suspended, because the observer cannot have received anything. Without this, an
observer returning from an outage longer than L would expire every peer at once
and then re-learn them, a flap storm.

Retained peers keep their slots while the transport is down, so a local
Advertise that needs a slot may evict the oldest suspended leased peer. That is
a bounded local recovery rule, not a wire signal; unleased peers are never
retained and are discarded at suspend.

**What would change this.** If the owner wants the existing "presence is
uncertain after a reset" semantics to stay uniform, keep today's discard and
change the acceptance item to "no departure event"; observers then re-learn
within R at the cost of a presence flap.

## Compatibility with peers on the shipped `axoloty/1`

`axoloty/1` shipped in v0.10.0; the Advertise path is unchanged through
v1.0.1 (`git diff v0.10.0 v1.0.1`).

- **Shipped decoder, new frame.** Decodes, ignores the new fields, and
  delivers the Advertise (Claim 3, measured under both profiles).
- **Shipped receiver that already holds the entry.** The refresh is
  `rejected(duplicate)`: nothing is delivered and no state changes (Claim 2). The
  host runtime still emits a `.transition(.rejected(...))` event for it
  (`AxolotyRuntime.swift`), so a shipped host sees one rejected transition per
  refresh per held object, at rate `(N−1)·M/R` (derived). This is noise, not
  corruption. Release notes must state it. It is the one real compatibility
  cost of option A and the reason option C is listed as the alternative.
- **Shipped receiver that does not hold the entry** (a late joiner): the
  refresh is delivered as an ordinary Advertise. This is a benefit: a shipped
  late joiner learns peers within R, which Zenoh's lack of retention otherwise
  prevents.
- **New receiver, shipped sender.** A peer that declares no lease is never
  expired. Its restart stays masked by `rejected(duplicate)` exactly as today,
  and nothing here repairs a shipped device that crashes; that needs the device
  to be updated.
- **`coaty/3`.** The fields exist only in `axoloty/1`, and a processor with
  presence off ignores them even if a `coaty/3` frame carried them, so
  `coaty/3` bytes and behaviour are unchanged. A regression test must show that
  a `coaty/3` Advertise carrying `leaseMs` and `ownerEpoch` is stored and
  delivered exactly like one without them and never expires.
- **Does this need `axoloty/2`?** No. The owner accepted the additive fields as
  an `axoloty/1` extension and directed that ADR 0008's "only the encoding
  differs" sentence gain a note; the accepted ADR is not rewritten.

### Golden corpus and `docs/wire-compatibility.md`

The corpus under `Tests/AxolotyTests/WireCompatibility/Golden` is frozen and is
"regenerated only in a dedicated, reviewed change" ([`testing.md`](../testing.md)).
The plan leaves every existing golden byte-identical (no existing `*.json` or
`*.cbor` file may appear in the diff) and adds new cases:

- CBOR cases: `advertise-lease` (`leaseMs` and `ownerEpoch`) and
  `advertise-refresh` (same fields, a refresh). Rejection vectors (`leaseMs`
  zero, above the bound, non-integer, `ownerEpoch` zero, one field without the
  other) do not round-trip; they live in processor and trace tests.
- The corpus pairs a JSON golden with each CBOR case. Presence is
  `axoloty/1`-only, so these cases need a CBOR-only manifest entry (a small
  schema change). The owner accepted CBOR-only entries; the Node verifier must
  compare the generator's logical value and reject an unpaired `.cbor` unless
  the manifest flag is present.
- `docs/wire-compatibility.md` gets a row in the `axoloty/1` change table with
  `coaty/3` effect "None; presence is off for `coaty/3` and the fields are not
  part of its profile" and a section recording the additive fields as a
  deliberate `axoloty/1` extension with this ADR as the linked decision.
- `docs/protocol/axoloty-1.md` gets the CDDL above.
- Host/static parity: the existing `WireCBORTraceParityTests` replays the host
  on `coaty/3` and the static runtime on `axoloty/1`. Presence needs both legs on
  `axoloty/1`, and the trace corpus needs time-advance steps for expiry and
  refresh. State, actions, and rejections must match.

## Storage growth in fixed-capacity state

Per object slot, presence adds a declared lease, a last-seen time, and an owner
epoch, each `UInt32` milliseconds or counter: **+12 bytes per slot**. A zero
lease means no lease; a zero epoch means no epoch.

| | Now | With presence | Source |
|---|---:|---:|---|
| `ObjectRecord` stride (replica with the same fields) | 36 B | 48 B | measured on a replica struct, because the real type is private; the field list is read from `ProtocolProcessor.swift` |
| `ProtocolProcessor<1/4/16/64>` total | 416 / 1,552 / 6,112 / 24,352 B | 428 / 1,600 / 6,304 / 25,120 B | measured base; growth derived as 12 B × capacity |
| Growth at 16 and 64 slots | | +192 B (+3.1 %) / +768 B (+3.2 %) | derived |

The processor's total grows about 380 B per capacity unit across its three
tables (measured: 6,112 to 24,352 B over 48 slots), so the object table
accounts for about a tenth of that (48 of about 386 B; derived). The static
runtime embeds the processor, so the same per-slot growth is expected there;
the static runtime was not measured. All of this is host layout only. Heap,
stack, and image size on the ESP32-C6 are not measured here and need device
evidence. The processor keeps the "no allocation" rule: all new state is fixed
inline and filled by the owner.

## Module ownership

This changes no ownership rule in `AGENTS.md`.

- `AxolotyWire`: the two optional Advertise fields and their bounds; golden
  vectors.
- `AxolotyProtocol`: the presence policy, three fixed `UInt32` fields per object
  record (lease, last seen, owner epoch), the refresh transition, and the expiry
  pass and identifier report.
  Time comes from the caller; there is no allocation, task, or timer.
- `Source/Runtime`: the host timer, the expiry evidence case, and delivery to
  event streams. It exposes no raw MQTT or raw route API.
- `AxolotyStaticRuntime`: the same transitions, driven by its caller.
- Hardware work (the device refresh loop, `presence-expiry` qualification,
  measurement of heap, stack, drops, and the real reconnect distribution) stays
  in `phynics/axoloty-embedded`.

## Acceptance of #1060 and where each item is proven

| #1060 acceptance item | Where |
|---|---|
| ADR records the decisions | This ADR, accepted 2026-11-26 |
| Host and static replay identical traces | Core: trace parity tests (both legs on `axoloty/1`) |
| Lost peer's objects removed within the lease; slots reusable | Core: processor tests (extends Claim 1) |
| Rebooted peer's next Advertise delivered | Core: processor tests (owner-epoch re-announce and the post-expiry row) |
| Short reconnect inside the lease causes no departure | Core: processor and runtime tests (suspend/resume) |
| Peer with no lease is never expired | Core: processor tests |
| `coaty/3` bytes and behaviour unchanged | Core: existing goldens untouched, plus the `coaty/3` regression test |
| Expiry reported without breaking the frozen enums | Core: additive processor pass and host stream tests |
| Live-wire evidence over Zenoh with an unclean client kill | **Needs device and live-router evidence**: Core `zenoh-live` for the host leg; `phynics/axoloty-embedded` for the device leg and its `presence-expiry` check beside `last-will` |

Items that only the embedded repository can produce: refresh and expiry on the
ESP32-C6, real reconnect and `DROP` loss behaviour, receive-queue drops at the
design target, heap, stack, and image size with the new fields.

## Verification performed

- Claims 1 to 3 and the layout figures: the Swift Testing run above.
- `make test-one` was not used for the experiment. A root build compiles the
  whole package graph and the tooling, and this node had about 4.3 GB of free
  disk; the standalone `Packages/AxolotyProtocol` package builds the same
  sources (the root `AxolotyProtocolTests` target uses the same path) with
  only `AxolotyWire` and `AxolotyObjectModel`.
- The repository validator was run before the PR; its result is recorded in the
  PR description.

## Decisions recorded

1. Additive, ignorable Advertise envelope fields are accepted inside
   `axoloty/1`; ADR 0008 gets an additive-field note. No new event code or
   profile.
2. Field names and bounds: `leaseMs` and `ownerEpoch`; `leaseMs` in
   1,000 to 3,600,000 ms and `ownerEpoch` in 1 to 2,147,483,647.
3. A silent renew is `.accepted` with zero actions; no new outcome case.
4. Expiry is reported through additive API: a processor pass returning
   identifiers and a host expiry stream over an additive value struct. The
   frozen public enums gain no cases, so presence can ship in a minor release.
5. Transport loss suspends presence; a transport-ready call re-bases retained
   leased peers and resumes. A local insert may evict the oldest suspended
   leased peer.
6. Golden corpus: CBOR-only entries, with the verifier comparing the logical
   value and requiring an explicit manifest flag. Rejection vectors live in
   processor and trace tests.
7. Support claim: 7 agents at `M <= 2` on `esp32C6Static` until measured. `M`
   counts the identity object; the claim is an exit-test target, not a
   guarantee.
8. Adjacent Associate rows: a re-announce releases them; expiry does not.
   Release for a peer lost without any absence signal remains outside this
   ADR.
9. One clock: the host stamps presence time with the runtime's monotonic clock
   for both inbound processing and expiry. The static runtime's caller supplies
   that time.
10. A renew emits no presence diagnostic. It does not clear the runtime's
    `presenceUncertain` flag; only a delivered announce or deadvertisement
    does.

## Consequences

- Zenoh gets crash detection bounded by the lease, and late joiners learn
  peers within one refresh interval.
- Shipped receivers see one rejected-duplicate transition per refresh per held
  object until they update.
- Traffic grows as N²·M/R; the fixed table, not traffic, is the first limit on a
  device.
- The processor gains three `UInt32` fields per object slot and passive functions, and still allocates nothing and owns no clock.
- The frozen action and evidence enums gain no cases; expiry is additive, so this can ship in a minor release.
- `coaty/3` is untouched, including its last will.

## Rejected alternatives

- **Zenoh liveliness.** Linear in N, but outside v1 scope by #796 and not in the
  device image. Revisit if the supported count must exceed the table bound.
- **Forge a Deadvertise on expiry.** It would be a fake wire event with no
  owner and would break the rule that a source removes only its own entries.
- **Tombstones or an owner generation.** See decision 5.
- **A digest per object.** See decision 2.
- **A shared, stateful presence service outside the processor.** It would add
  a second state machine and break host and static parity.
