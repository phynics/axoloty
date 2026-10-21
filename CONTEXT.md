# Axoloty

Axoloty is a bounded, Embedded-Swift-capable distributed object runtime with Coaty wire semantics.

## Language

**Runtime profile**:
A supported Axoloty execution environment that shares protocol semantics while selecting capabilities and resource policies.

**Host runtime profile**:
The full runtime profile for unconstrained Swift platforms.
_Avoid_: host implementation

**Static runtime profile**:
A bounded runtime profile with fixed composition and bounded state; embedded firmware is one deployment of it.
_Avoid_: embedded implementation

**Portable protocol path**:
The shared interpretation and state-transition path used by every runtime profile.
_Avoid_: embedded path, host path

**Protocol suite**:
The set of protocol profiles understood by an Axoloty runtime.

**Wire profile**:
A protocol profile's route prefix and payload encoding. `coaty/3` (JSON) and `axoloty/1` (CBOR) are separate wire profiles.

**Coaty Core Profile 3**:
The sealed Coaty compatibility profile that uses the `coaty/3` route binding and JSON encoding.

**Axoloty extension profile**:
A separately versioned Axoloty protocol profile for behavior that cannot safely be composed from Coaty Core Profile operations. `axoloty/1` is the current extension profile.

**Native profile**:
The `axoloty/1` CBOR protocol profile used for Axoloty-native communication.

**Wire domain**:
A profile-specific route and encoding space shared by communicating peers. `coaty/3` and `axoloty/1` are separate wire domains.

**Object authority**:
The application owns durable object data and conflict resolution. Axoloty provides bounded object representation and protocol operations, not a shared source of truth.

**Experimental product**:
An Axoloty package, product, or tool outside the six-product Core 1.0 stability contract. Its public interface is not covered by that contract.

**Protocol action**:
A normalized consequence of protocol processing for a runtime adapter or application.

**Capability**:
A protocol behavior understood by Axoloty and enabled for a particular runtime profile.

**Runtime builder**:
The finite mutable ``RuntimeBuilder`` used to register handlers, event
streams, typed IO endpoints, and first-party runtime modules before startup.

**Runtime definition**:
The immutable ``RuntimeDefinition`` produced by consuming a runtime builder.
It contains configuration and sealed registration state, but no registration
or sealing methods.

**Runtime module**:
A bounded first-party lifecycle registration attached to a runtime under a
stable internal key. Modules use ``RuntimeModuleContext`` and
``RuntimeModuleRegistration``; they do not own transport or protocol state.

**SensorThings source**:
A typed Sensor/Thing producer installed in the single optional
`AxolotySensorThings` runtime module. Its Sensor envelope names the parent
Thing, and its producer publishes through the existing runtime operations.

**Direct SensorThings observation**:
A fixed-Sensor observation stream that consumes one configured Channel and
accepts only Observation envelopes parented by that Sensor. It performs no
metadata discovery.

**Object envelope**:
The standard protocol-level identity and metadata shared by Coaty objects.

**Dynamic object**:
An owned object whose schema-specific fields are accessed without compile-time schema knowledge.

**Object schema**:
A compile-time description of an object type's schema-specific fields.

**Portable object schema**:
The fixed descriptor and codecs shared by manual and macro-generated object
schema conformances.

**Typed object**:
An `Object<Schema>` combining an object envelope with a statically known object schema.

**Presence**:
An explicit field state that distinguishes missing, JSON null, and a value.

**Schema registry**:
A caller-owned, fixed-capacity, runtime-local set of object schemas that is
explicitly populated and sealed before use.
_Avoid_: global class registry

**Object predicate**:
A bounded typed expression for Coaty-compatible object-filter encode, decode,
and local evaluation.

**External IO route**:
A transport-binding-specific non-Coaty route associated with a Coaty IO endpoint.
_Avoid_: raw MQTT route
