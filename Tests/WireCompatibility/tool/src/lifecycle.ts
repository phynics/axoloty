// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";

interface Scenario {
  participants: string[];
  status: "executable" | "unsupported";
  reason: string;
}

const qosLimitation = "Pinned CoatyJS 2.4.0 publishes only at QoS 0; higher QoS scenarios are unsupported by the reference binding.";
const scenarios: Record<string, Scenario> = {
  "offline-queueing": executable("Axoloty publishes through a severed and restored TCP path."),
  "reconnect-resubscribe": executable("Axoloty reconnects through a severed and restored TCP path."),
  "broker-restart": executable("Axoloty reconnects after Mosquitto is stopped and restarted."),
  "clean-session": executable("The TCP proxy records repeated clean MQTT handshakes."),
  "duplicate-reply": executable("CoatyJS sends duplicate Call/Return replies."),
  "late-reply": executable("CoatyJS sends a reply after Axoloty's response deadline."),
  "unexpected-disconnect-last-will": executable("The broker publishes CoatyJS's last will after an unexpected disconnect."),
  "qos-0": executable("CoatyJS publishes the deterministic object at QoS 0."),
  "graceful-deadvertise": executable("CoatyJS publishes Deadvertise after graceful shutdown."),
  "qos-1": unsupported(qosLimitation),
  "qos-2": unsupported(qosLimitation),
};

function executable(reason: string): Scenario {
  return { participants: ["axoloty", "coatyjs-2.4.0"], status: "executable", reason };
}

function unsupported(reason: string): Scenario {
  return { participants: ["axoloty", "coatyjs-2.4.0"], status: "unsupported", reason };
}

/** Write the retained evidence manifest for one lifecycle scenario. */
export function writeLifecycleManifest(scenarioId: string, applicationLog: string | undefined, capture: string | undefined, output: string): void {
  const scenario = scenarios[scenarioId];
  if (!scenario) throw new Error(`unknown lifecycle scenario: ${scenarioId}`);
  if (scenario.status === "unsupported") {
    writeFileSync(output, JSON.stringify({ format: "axoloty-lifecycle-evidence/v1", scenario: scenarioId, status: scenario.status, limitation: scenario.reason, participants: scenario.participants }, null, 2) + "\n");
    return;
  }
  if (!applicationLog || !capture) throw new Error(`${scenarioId} requires --application-log and --capture`);
  writeFileSync(output, JSON.stringify({
    format: "axoloty-lifecycle-evidence/v1",
    scenario: scenarioId,
    status: "executed",
    limitation: scenario.reason,
    evidence: { applicationLog: artifact(applicationLog, true), capture: artifact(capture, true) },
  }, null, 2) + "\n");
}

function artifact(path: string, jsonLines: boolean): Record<string, string | number> {
  const bytes = readFileSync(path);
  if (!statSync(path).isFile() || bytes.length === 0) throw new Error(`required evidence is missing or empty: ${path}`);
  const lines = bytes.toString("utf8").split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (jsonLines) {
    if (lines.length === 0) throw new Error(`required capture has no records: ${path}`);
    for (const line of lines) JSON.parse(line);
  }
  const result: Record<string, string | number> = { path: path.split("/").pop() ?? path, sha256: createHash("sha256").update(bytes).digest("hex") };
  if (jsonLines) result.records = lines.length;
  return result;
}
