# Force-Unwrap Audit

Audit of force-unwraps (`!`) and force-casts (`as!`) reachable from a peer
wire payload or downstream SDK-consumer configuration, done as part of #139.
Sites that are safe-by-construction (lifecycle-guaranteed IUOs, already
guarded by an adjacent nil-check) are out of scope for conversion and are not
re-litigated here; only sites confirmed to represent a genuine crash risk are
listed.

## Converted sites

| Site | Verdict | Reason |
|---|---|---|
| `Communication/Manager/CommunicationManager.swift` (`handleAssociate`, `event.data.isExternalRoute!`) | converted → `?? false` | Peer-received Associate event; CoatyJS 2.4.0 never sends `isExternalRoute` (#31 recurrence risk). Defaults to `false` instead of trapping on a legacy peer's payload. |
| `Communication/Manager/CommunicationManager.swift` (`init`, `communicationOptions.mqttClientOptions!`) | converted → `throw AxolotyError.invalidConfiguration` | Downstream integrator config, not user input the SDK controls. A missing `mqttClientOptions` now throws instead of trapping `init`. `init`/the public convenience `init` are now `throws`; `Container.resolveComponents` catches and logs `.critical`, leaving `communicationManager` `nil` (already an anticipated state per the existing `startAndWaitUntilReady` guard). |
| `Communication/Manager/CommunicationManager.swift` (`startClient`, `communicationOptions.mqttClientOptions!`) | converted → `throw AxolotyError.invalidConfiguration` | Same as above but on the restart path; `startClient()`/`start()` are now `throws`. The one auto-start caller (`didReceiveStart`) catches and logs `.error` instead of propagating (delegate callback cannot throw). |
| `Model/ObjectFilter.swift:189` (`OrderByProperty.init(from:)`, `SortingOrder(rawValue:)!`) | converted → `throw DecodingError.dataCorruptedError` | Wire-reachable via a peer's Query/objectFilter payload; an unrecognized sort order string now fails decoding instead of trapping. |
| `Model/ObjectFilter.swift:508` (`ObjectFilterExpression.init(from:)`, `ObjectFilterOperator(rawValue:)!`) | converted → `throw DecodingError.dataCorruptedError` | Same reasoning; an unrecognized filter operator int now fails decoding instead of trapping. |
| `SensorThings/CoatyTimeInterval.swift:117,119` (`toLocalIntervalIsoString`, `self._start!`/`self._end!`) | converted → validating `init(from:)` | The four designated initializers each enforce exactly one of the valid start/end/duration combinations, but a synthesized `Decodable` conformance bypassed that invariant for wire-decoded instances. Added an explicit `init(from:)` that validates the combination and throws `DecodingError.dataCorruptedError` on an invalid one; the two force-unwraps are now genuinely safe by construction on every path, decoded or not. |
| `Runtime/Container.swift` (`createIdentity`, `value as! String` / `value as! CoatyUUID`) | converted → guarded cast, `throw AxolotyError.invalidConfiguration` | `CommonOptions.agentIdentity` is downstream-SDK-consumer config (the removed inline comment mislabeled it "not user input"). `createIdentity` is now `throws`; `resolveComponents` catches, logs `.critical`, and falls back to a default `Identity` rather than trapping container resolution. |
| `Common/PayloadCoder.swift:37` (`encode`, `try! JSONEncoder().encode(event)`) | converted → `throws`, wraps via `AxolotyError.caught` | `JSONEncoder` can throw for values it cannot represent (e.g. a `Double` field holding `NaN`/`infinity` set by downstream application code, such as a `SensorThings` observation result). `PayloadCoder.encode` is now `throws`. The `CommunicationEvent.json`/`CoatyObject.json` convenience properties (read from dozens of non-throwing publish call sites) catch, log `.error` via `ErrorKit.errorChainDescription`, and fall back to `"{}"` rather than propagating or trapping. |
| `Communication/Client/BonjourResolver.swift:86` (`netServiceDidResolveAddress`, `sender.addresses!`) | converted → `guard let` | OS delegate callback; `NetService.addresses` is a plain `[Data]?`, not guaranteed non-nil by the time the delegate fires. Now guarded alongside the existing `resolveIPv4Addresses` call. |

## Confirmed invariants (left as-is)

| Site | Reason |
|---|---|
| `Common/PayloadCoder.swift:19` (`decode`, `jsonString.data(using: .utf8)!`) | `String.data(using: .utf8)` cannot fail for a Swift `String`; Swift strings are always representable in UTF-8. Documented with an inline comment. |
| `Common/PayloadCoder.swift` (`encode`, `String(data: jsonData, encoding: .utf8)!`) | `JSONEncoder` output is valid UTF-8 by spec. Documented with an inline comment. |
| `Communication/Manager/CommunicationManager.swift` (`init` and `startClient`, `try! initializeNamespace()`) | Fail-fast invariant on a normalized string derived from `CommunicationOptions.namespace`, not user input. |
| `Communication/Manager/CommunicationManager.swift` (`init`, `try! self._initIoNodes()`) | Fail-fast invariant on the internally-constructed IO node graph; not reachable from peer payloads or downstream config. |
| `Communication/Manager/CommunicationManager.swift` (`startClient`, `try! _initIoNodes()`) | Same invariant as the `init` path; re-initializes IO nodes on restart. |
| `Communication/Manager/CommunicationManager.swift` (`advertiseIdentity`, `try! publishAdvertise(...)`) | `self.identity` is always a valid, internally-created `Identity` object; encoding cannot fail. Fail-fast invariant, not user input. |
| `Communication/Manager/CommunicationManager.swift` (`handleAssociate`, `ioActor!`) | Guarded by the `isIoActorAssociated` check earlier in the same function; control flow guarantees non-nil before use. |
| `Communication/Client/MQTTNIOClient.swift` (`init`, `try! startDiscoveryIfNeeded(...)`) | Fail-fast invariant on internally-derived MQTT client options; `startDiscoveryIfNeeded` only throws `.brokerUnavailable` for a platform configuration issue, which is set before this call and already validated. |
| `Runtime/Container.swift` (`resolveComponents`, `self.identity!`) | Set unconditionally on the line immediately above; never accessed before assignment. |
| `subscriptionCoordinator!`, `client!` and similar lifecycle-owned IUOs across `CommunicationManager.swift`/`MQTTNIOClient.swift` | Set once during `init`/`configure` and never accessed before that point; safe-by-construction, not reachable from peer payloads or downstream config. Out of scope per the ticket's "leave the safe-by-construction IUO family as-is" guidance. |

## Explicitly out of scope

Per the ticket, `Common/ObjectMatcher.swift`, `Communication/Misc/CommunicationTopic.swift`,
`Common/Codable+JSON.swift`, `IORouting/IoRouter.swift`, the guarded sites in
`Common/Decoder+Context.swift`, and `Common/AnyCodable/AnyCodable.swift` were
not touched — all are confirmed already-guarded by adjacent nil-checks.
