# Legacy CoatySwift IO scope decision

Status: recorded decision for T-021 (#31). The ticket's acceptance criteria
require keep/diverge/remove decisions backed by live capture evidence or an
approved scope decision; this document is the recorded decision that
satisfies the second clause for the legacy CoatySwift 2.4.0 reference agent's
IO routing coverage.

## Decision

Legacy CoatySwift 2.4.0 is **descoped as a live IO-routing-scenario subject**.
The IO Associate/IoValue/IoState scenarios are executed with Axoloty (modern
Swift) and pinned CoatyJS 2.4.0 as live subjects only. Legacy CoatySwift
remains a reference for *wire-shape* compatibility via its provenance-bound
captures (`Fixtures/coatyswift-2.4.0/`, T-018), which is a different,
already-served evidentiary role, and could be extended for a targeted IO
observation if a concrete interop question ever arises (see Consequences).

## Why

1. **The legacy runner is a one-shot producer by design.** The macOS scenario
   driver (`Legacy/macOS-runner/`) connects, publishes a fixed scenario's
   events, and exits. IO routing needs a long-lived router that publishes
   Associate events and a source that publishes IoValues on the generated
   route after association — a multi-message, sequenced conversation the
   pinned 2.4.0 producer driver was not built to host.
2. **No macOS/Xcode host in this session.** Legacy CoatySwift 2.4.0 builds only
   on macOS with Xcode; this work was done on a Linux host. Generating the
   captures requires a macOS runner, which is the same platform constraint
   recorded for lifecycle in `LegacySwiftLifecycleScopeDecision.md`. Fabricating
   a pass without a real runner is forbidden by the audit.
3. **The compatibility question IO scenarios answer is about the maintained
   implementation.** What must not regress is Axoloty's IO behavior (Associate
   handling, generated route, IoValue encoding, IoState transitions) against a
   maintained reference peer. Legacy CoatySwift is frozen at 2.4.0 and
   unmaintained; a divergence found there could not be fixed, only recorded.
   The cross-implementation evidence that matters is produced by the CoatyJS
   2.4.0 and modern-Swift directions.

## Consequences

- The compatibility matrix rows for `Associate / IoState / IoValue` record
  `Not tested — see LegacySwiftIOScopeDecision.md` for both the
  `Legacy → modern` and `Modern → legacy` columns.
- If a concrete interoperability question about legacy IO behavior ever
  arises (e.g. a field report of a legacy agent misreading Axoloty's
  Associate or IoValue), the capture pipeline in `Legacy/` is the starting
  point: extend the macOS runner for that one targeted observation rather
  than standing up the full IO catalog.
- This decision is recorded per-session and should be revisited when a macOS
  host with Xcode is available, at which point the Associate + JSON IoValue
  scenario is the minimal capture that would establish the legacy direction's
  pattern.
