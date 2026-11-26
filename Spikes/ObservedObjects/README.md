# Bounded observable objects spike

This isolated host package tests the first slice of
[#1044](https://github.com/phynics/axoloty/issues/1044). The test target uses
the public Axoloty runtime and an in-process transport. It needs no broker,
hardware, or application schema macros.

Run the tests in the pinned development container.

```sh
Spikes/ObservedObjects/check-host.sh
```

The package resolves the separately selectable experimental
`AxolotyObservedObjects` product through a path dependency. The test
package owns its lockfile and build directory.

The view holds a fixed set of watched object IDs and up to two candidates
per ID. With eight IDs and 2 KiB per candidate, the retained payload budget
is 32 KiB. Stream storage, temporary decoding, and snapshots have additional
costs. A snapshot reports the age of local evidence. The application provides
any revision ordering and decides how to interpret a disagreement.

A host event carries a wrapping receipt timestamp and no transport epoch.
The receipt-time helper assumes a verified window on the binding's monotonic
clock. It preserves the event's age across wrap and rejects a timestamp
outside that window. An epoch change keeps passive evidence uncertain for
the attachment. A fresh, explicitly requested Discover can collect evidence
for its own correlation in the new epoch. An empty window yields
`noSample`. The public counters cannot account for every frame that Core
rejects before application delivery.

The host trace runs against both `coaty/3` JSON and `axoloty/1` CBOR. It
leaves the application streams undrained while Core accepts an Advertise
and a Resolve. After reconnect, it drains the old values, rejects the old
correlation and a wrong object ID, then admits the matching new Resolve to
the view. The projection tests also demonstrate a manual JSON schema and
an exact-byte fallback for an unknown application schema version.

The withdrawal tests send arrays that contain both UUIDs and opaque
identifiers. A mixed valid array records source-scoped uncertainty. A
malformed array leaves the view unchanged.
