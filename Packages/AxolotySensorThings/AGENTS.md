# AxolotySensorThings instructions

The root [`AGENTS.md`](../../AGENTS.md) rules apply to this optional host
product. `AxolotySensorThings` owns typed SensorThings source and direct
observation workflows while `AxolotyProtocol` remains the protocol authority
and `AxolotyRuntime` remains the lifecycle, transport, and task owner.

Keep registration finite and atomic through the runtime builder. Source
snapshots are copied before they enter asynchronous coordinator tasks. A
single bounded coordinator owns producers and observation streams; use the
runtime module lifecycle rather than creating a transport, processor, or
detached task hierarchy. Keep SensorThings on the existing Coaty operation
families and typed runtime SPI. Do not expose raw MQTT topics or resurrect
the retired controller APIs.
