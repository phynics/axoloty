// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const output = process.argv[2];
if (!output) throw new Error("output path is required");
const values = {
  ssid: process.env.AXOLOTY_WIFI_SSID,
  password: process.env.AXOLOTY_WIFI_PASSWORD,
  host: process.env.AXOLOTY_MQTT_HOST || "192.168.178.160",
  port: process.env.AXOLOTY_MQTT_PORT || "1883",
  role: process.env.AXOLOTY_DEVICE_ROLE || "none",
  scenario: process.env.AXOLOTY_AGENT_SCENARIO || "exchange",
  runtimeIdentity: process.env.AXOLOTY_RUNTIME_IDENTITY || "",
};
if (!values.ssid || !values.password) throw new Error("Wi-Fi configuration is required");
if (!/^[0-9]+$/.test(values.port) || Number(values.port) < 1 || Number(values.port) > 65535) {
  throw new Error("invalid MQTT port");
}
if (!["none", "A", "B"].includes(values.role)) throw new Error("invalid device role");
if (!["exchange", "last-will", "broker-restart"].includes(values.scenario)) throw new Error("invalid agent scenario");
if (!/^[A-Za-z0-9._-]{0,63}$/.test(values.runtimeIdentity)) throw new Error("invalid runtime identity");
for (const [name, value] of Object.entries(values).slice(0, 3)) {
  const max = name === "ssid" ? 32 : 63;
  if (Buffer.byteLength(value, "utf8") === 0 || Buffer.byteLength(value, "utf8") > max) {
    throw new Error(`invalid ${name} length`);
  }
}
const bytes = value => [...Buffer.from(value, "utf8"), 0].join(", ");
const role = { none: 0, A: 1, B: 2 }[values.role];
const scenario = { exchange: 0, "last-will": 1, "broker-restart": 2 }[values.scenario];
const header = `// Generated private build input; do not commit or log values.\n#ifndef AXOLOTY_NETWORK_CONFIG_H\n#define AXOLOTY_NETWORK_CONFIG_H\n#include <stddef.h>\n#define AXOLOTY_NETWORK_CONFIGURED 1\nstatic const unsigned char axoloty_wifi_ssid[] = { ${bytes(values.ssid)} };\nstatic const size_t axoloty_wifi_ssid_length = sizeof(axoloty_wifi_ssid) - 1;\nstatic const unsigned char axoloty_wifi_password[] = { ${bytes(values.password)} };\nstatic const size_t axoloty_wifi_password_length = sizeof(axoloty_wifi_password) - 1;\nstatic const char axoloty_mqtt_host[] = { ${bytes(values.host)} };\nstatic const unsigned int axoloty_mqtt_port = ${Number(values.port)}U;\nstatic const unsigned int axoloty_device_role = ${role}U;\nstatic const unsigned int axoloty_agent_scenario = ${scenario}U;\nstatic const char axoloty_runtime_identity[] = { ${bytes(values.runtimeIdentity)} };\n#endif\n`;
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, header, { mode: 0o600 });
