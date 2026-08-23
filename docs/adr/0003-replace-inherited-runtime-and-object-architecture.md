---
status: accepted
---

# Replace the inherited runtime and object architecture

Axoloty 0.6 replaces the Container/controller/global class-registry architecture with a structured `AxolotyRuntime`, immutable pre-start definition, value-oriented object schemas, and typed handlers and endpoints. Keeping the inherited architecture as a primary or parallel compatibility runtime would prolong host/static divergence and ambiguous lifecycle ownership.
