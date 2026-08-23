# Test instructions

## Jurisdiction

This guide applies to `Tests/`. The root [`AGENTS.md`](../AGENTS.md) rules apply; this guide specializes them for test policy, compatibility evidence, and canonical test-manifest ownership.

## Specialized rules

[`docs/testing.md`](../docs/testing.md) and the canonical manifest own test tiers, policies, and compatibility aliases. Use root Make targets; do not reproduce container invocations.

Swift tests use Swift Testing: `import Testing`, `@Test`, `#expect`, `#require`, and `Issue.record`. Broker-backed tests synchronize with Swift concurrency primitives or explicit deadlines. Ordinary tests are hardware-free.

Wire compatibility uses the pinned CoatyJS reference agent. Protocol-affecting changes require regression coverage, compatibility-matrix updates, and the applicable fixture/live evidence. Offline fixture evidence and fresh live-wire evidence are distinct and must not be represented as interchangeable.

The 0.6 non-divergence suite must execute identical protocol traces across host and static runtime profiles for overlapping capabilities and compare next state, normalized actions, and structured rejection outcomes.
