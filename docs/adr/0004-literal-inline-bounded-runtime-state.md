---
status: proposed
---

# Use literal-inline bounded runtime state

Protocol and static-runtime state should use noncopyable literal-inline storage with named capacity presets, and the host should use the same bounded algorithms. This remains proposed until [G1](https://github.com/phynics/axoloty/issues/629) proves the approach on the pinned host and ESP32-C6 toolchains; if it is materially infeasible, the decision will explicitly adopt evidence-backed construction-time fixed allocation instead.
