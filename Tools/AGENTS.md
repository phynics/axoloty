# Tools instructions

`AxolotyTooling` is the typed repository orchestration control plane. Keep root Make recipes and shell launchers thin; new orchestration policy, command validation, and lifecycle behavior belong in the tooling package.

Inspector and MCP are first-party development tools. They consume supported runtime interfaces and must not introduce privileged protocol backdoors or tool-specific concepts into the core. If arbitrary MQTT packet access is required, use a tool-owned transport client rather than enlarging the Axoloty runtime API.

Keep tooling bootstrap independent of product-runtime compilation where practical. Dynamic command output belongs on stderr when stdout is a machine-readable contract.
