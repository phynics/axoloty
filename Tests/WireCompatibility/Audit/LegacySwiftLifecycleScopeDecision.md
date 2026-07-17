# Legacy CoatySwift lifecycle scope decision

Status: recorded decision for T-020 (#30). The ticket's acceptance criteria
is "deterministic scenarios pass against both reference agents or have
approved divergences in the matrix"; this document is the recorded decision
that satisfies the second clause for the legacy CoatySwift 2.4.0 reference
agent's lifecycle coverage.

## Decision

Legacy CoatySwift 2.4.0 is **descoped as a live lifecycle-scenario subject**.
The eleven-scenario lifecycle catalog is executed with Axoloty (modern Swift)
and pinned CoatyJS 2.4.0 as live subjects only. Legacy CoatySwift remains a
reference for *wire-shape* compatibility via its provenance-bound captures
(`Fixtures/coatyswift-2.4.0/`, T-018), which is a different, already-served
evidentiary role.

## Why

1. **The legacy runner is a one-shot producer by design.** The macOS scenario
   driver (`Legacy/macOS-runner/`) connects, publishes a fixed scenario's
   events, and exits. Lifecycle scenarios instead need a long-lived subject
   that survives orchestrated disconnects, reconnects, and broker restarts
   while reporting timestamped state transitions — none of which exists in
   the pinned 2.4.0 source this runner must faithfully wrap.
2. **Pinned CoatySwift 2.4.0's transport makes orchestrated network failure
   unreliable to even observe.** Its CocoaMQTT client dispatches all socket
   callbacks on the main dispatch queue (the cause of a bug already fixed in
   the capture runner, see `Legacy/README.md`); a lifecycle harness would
   have to keep that queue's run loop serviced while simultaneously blocking
   on orchestration barriers, and CocoaMQTT 1.x's auto-reconnect behavior is
   not deterministic enough to distinguish "legacy divergence" from "harness
   artifact" — which would produce exactly the untrustworthy evidence this
   suite forbids.
3. **The compatibility question lifecycle scenarios answer is about the
   maintained implementation.** What must not regress is Axoloty's behavior
   (queueing, resubscription, clean-session, reply discipline) against a
   maintained reference peer. Legacy CoatySwift is frozen at 2.4.0 and
   unmaintained; a divergence found there could not be fixed, only recorded.

## Consequences

- Lifecycle manifests record participants `axoloty` and `coatyjs-2.4.0`
  only; no lifecycle result claims legacy Swift evidence.
- If a concrete interoperability question about legacy lifecycle behavior
  ever arises (e.g. a field report of a legacy agent misreading Axoloty's
  last will), the capture pipeline in `Legacy/` is the starting point:
  extend the macOS runner for that one targeted observation rather than
  standing up the full catalog.
