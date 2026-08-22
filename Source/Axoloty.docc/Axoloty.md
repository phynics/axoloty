# ``Axoloty``

Axoloty is a Swift implementation of the Coaty Core 3 wire profile. The
public host runtime is immutable after configuration, and the portable
protocol processor is shared with the fixed-storage static runtime.

## Overview

Configure a ``RuntimeDefinition`` with ``RuntimeDefinition/Builder``, then
start one ``AxolotyRuntime`` with an ``MQTTBinding``. Transport bytes are
copied at the binding boundary, processed by ``AxolotyProtocol``, and exposed
as owned ``RuntimeEventValue`` values. The host runtime owns lifecycle and
concurrency; protocol semantics remain in the shared processor.

The static profile uses `AxolotyStaticRuntime` and caller-owned fixed
storage. It is suitable for embedded builds and does not depend on actors,
Foundation, MQTT, or dynamic protocol state.

Failures are represented by ``AxolotyError`` at the public boundary. Runtime
health is available through ``RuntimeState`` and bounded
``RuntimeDiagnostics`` snapshots and streams.

For a compiling introduction, see <doc:GettingStarted>.

## Topics

### Runtime

- ``RuntimeDefinition``
- ``RuntimeDefinition/Builder``
- ``AxolotyRuntime``
- ``RuntimeState``
- ``RuntimeEventValue``
- ``RuntimeDiagnostics``

### Transport

- ``MQTTBinding``
- ``MQTTBindingConfiguration``

### Errors

- ``AxolotyError``

### Articles

- <doc:GettingStarted>
- [Logging](Logging.md)
