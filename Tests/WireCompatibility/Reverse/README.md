# Axoloty → CoatyJS live compatibility

This scenario starts pinned CoatyJS 2.4.0 as a consumer, publishes a fixed
Advertise event from Axoloty, and requires CoatyJS to decode and acknowledge
all protocol-significant object fields.

Run from the repository root:

```sh
Tests/WireCompatibility/Reverse/run-axoloty-advertise.sh
```

The Swift XCTest is environment-gated and skips during the normal test suite.
