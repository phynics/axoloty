# Post-Modernization Roadmap (Phases 7-8)

Source epic: #43 (Modernization Roadmap Completion) is closing out with only
Phase 6's compatibility-decision items left (#31, #32). This plan extends the
roadmap with the next two phases, drawn from tickets that accumulated during
the async/streaming migration but were never grouped under a phase.

## Phase 7 — Runtime correctness (EventHub/streaming + IO routing)

The RxSwift → async/await migration (Phase 3) left a cluster of correctness
gaps around event delivery and IO routing that are tracked as standalone bugs
with no owning epic. Group and close them together since they share root
causes (unstructured task spawning, stream lifecycle, low-level EventHub
surface):

- [ ] #70 — Response events can be lost before callers attach an iterator
- [ ] #74 — EventStream unsafe with normal 'for await' use — early events lost
- [ ] #55 — Query and Call event observation lost with no async-stream replacement
- [ ] #56 — Delegate callbacks spawn unstructured Task per message — MQTT ordering not guaranteed
- [ ] #72 — Uniterated stream retains its MQTT subscription indefinitely
- [ ] #54 — CM+Publish.responseStream force-unwraps subscriptionCoordinator! — crash race on stop
- [ ] #73 — Public EventHub is too low-level for the package boundary
- [ ] #76 — PayloadCoder.encode has a hidden crash contract via try!
- [ ] #61 — Scope creep in RxSwift-removal commit (Makefile arg reorder + dropped wait-for-online guard)
- [ ] #63 — Discover handling re-implemented in three places — extract shared discover-responder
- [ ] #65 — Dead stub setup*Handler()/setup*Logging() methods and empty onFirst: {} closures
- [ ] #66 — Data clump / primitive obsession across topic-string call sites and IoSourceController

## Phase 8 — Wire test infrastructure

Replace the Python wire-compatibility harness with an npx-runnable Node CLI
plus Swift Testing verification, per #120:

- [x] #121 — Scaffold npx-runnable Node CLI package
- [x] #122 — Replace vendored CoatyJS node_modules with real npm dependency
- [x] #123 — Rewrite wire-capture semantic verification in Swift Testing
- [x] #124 — Wire up Makefile + CI workflow to the new CLI, delete remaining Python
- [x] #125 — Add JS -> modern live scenarios (Deadvertise, Discover/Resolve, Query/Retrieve, Update/Complete, Call/Return, Channel)
- [x] #119 — Exercise objectFilter in the live Modern → JS Query/Retrieve scenario

Execution order: #121 → #122 → #123 → #134 → #124. #125 can proceed after
#123 once the shared harness surface is stable. The capture CLI's passive
`capture`, `run`, `manifest`, `lifecycle-manifest`, `legacy-manifest`, and
`proxy` commands are available.

## Explicitly out of scope for this epic

Tracked separately, not gated on or by this epic:
- #127 (Phase 7, WASM exploration)
- #96 (Embedded Swift target) and its dependents #97, #98, #110, #111, #113
- #115 (IO routing bounded-cost epic) and its dependents #116, #117
- #31, #32 (final two Phase 6 items — stay under #43)
- #133, #132, #134 (freshly filed today; triage separately, fold into Phase 8 later if they turn out to share root cause)
