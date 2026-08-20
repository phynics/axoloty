---
status: accepted
---

# Share the protocol critical path across runtime profiles

Host and static runtimes will use one portable processor for wire interpretation, routing keys, correlation, duplicate and deadline behavior, association transitions, and outbound operations. Profiles may differ in capacity, transport, ownership, delivery, scheduling, and diagnostics; sharing only codecs or maintaining separate state machines would preserve the drift this alignment is intended to remove.
