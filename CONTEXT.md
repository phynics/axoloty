# Axoloty

Axoloty is a Swift runtime and protocol suite for collaborative distributed agents across host systems and constrained devices.

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

**Coaty Core Profile 3**:
The sealed, compatibility-governed Coaty protocol profile using the `coaty/3` binding.

**Axoloty extension profile**:
A separately versioned first-party protocol profile for primitives that cannot safely be composed from Coaty Core Profile operations.

**Protocol action**:
A normalized consequence of protocol processing for a runtime adapter or application.

**Capability**:
A protocol behavior understood by Axoloty and enabled for a particular runtime profile.

**Object envelope**:
The standard protocol-level identity and metadata shared by Coaty objects.

**Dynamic object**:
An owned object whose schema-specific fields are accessed without compile-time schema knowledge.

**Object schema**:
A compile-time description of an object type's schema-specific fields.

**Typed object**:
An `Object<Schema>` combining an object envelope with a statically known object schema.

**External IO route**:
A transport-binding-specific non-Coaty route associated with a Coaty IO endpoint.
_Avoid_: raw MQTT route
