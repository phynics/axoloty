// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { atomicWriteFileSync } from "./atomic.js";

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
export function writeLifecycleManifest(scenarioId: string, applicationLog: string | undefined, capture: string | undefined, output: string, unsupportedReason?: string): void {
  const scenario = scenarios[scenarioId];
  if (!scenario) throw new Error(`unknown lifecycle scenario: ${scenarioId}`);
  if (unsupportedReason || scenario.status === "unsupported") {
    atomicWriteFileSync(output, JSON.stringify({ format: "axoloty-lifecycle-evidence/v1", scenario: scenarioId, status: "unsupported", limitation: unsupportedReason ?? scenario.reason, participants: scenario.participants }, null, 2) + "\n");
    return;
  }
  if (!applicationLog || !capture) throw new Error(`${scenarioId} requires --application-log and --capture`);
  verifyLifecycleBehavior(scenarioId, applicationLog, capture);
  atomicWriteFileSync(output, JSON.stringify({
    format: "axoloty-lifecycle-evidence/v1",
    scenario: scenarioId,
    status: "executed",
    limitation: scenario.reason,
    evidence: { applicationLog: artifact(applicationLog, true), capture: artifact(capture, true) },
  }, null, 2) + "\n");
}

interface LifecycleLogEntry {
  state?: string;
  at?: string;
  [key: string]: unknown;
}

interface CaptureRecord {
  capturedAt?: string;
  mqtt?: { topic?: string };
  payload?: { encoding?: string; bytes?: string };
}

const requiredStates: Record<string, string[]> = {
  "offline-queueing": ["ready", "offline", "published-offline", "reconnected", "done"],
  "reconnect-resubscribe": ["ready", "offline", "reconnected", "probe-received", "done"],
  "broker-restart": ["ready", "offline", "reconnected", "probe-received", "done"],
  "clean-session": ["ready", "offline", "reconnected", "probe-received", "done"],
  "duplicate-reply": ["ready", "accepted", "ignored", "done"],
  "late-reply": ["ready", "gave-up", "done"],
};

/** Validate the causal application/capture contract for the modern subjects. */
export function verifyLifecycleBehavior(scenarioId: string, applicationPath: string, capturePath: string): void {
  const application = parseJSONLines<LifecycleLogEntry>(applicationPath);
  const expected = requiredStates[scenarioId];
  if (expected) {
    const actual = application.map((entry) => entry.state).filter((state): state is string => typeof state === "string");
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error(`${scenarioId} application states ${JSON.stringify(actual)} do not equal ${JSON.stringify(expected)}`);
    }
  }

  const capture = parseJSONLines<CaptureRecord>(capturePath);
  if (scenarioId === "offline-queueing") {
    const payloads = capture
      .filter((record) => record.mqtt?.topic?.includes("/ADV/"))
      .map(decodePayload)
      .filter((payload): payload is string => payload !== undefined);
    const first = payloads.filter((payload) => payload.includes('"name":"first"'));
    const second = payloads.filter((payload) => payload.includes('"name":"second"'));
    if (first.length !== 1 || second.length !== 1 || payloads.indexOf(first[0]!) > payloads.indexOf(second[0]!)) {
      throw new Error("offline-queueing capture must contain first then second exactly once");
    }
  } else if (scenarioId === "duplicate-reply") {
    const returns = capture.filter((record) => record.mqtt?.topic?.includes("/RTN/"));
    const texts = returns.map(decodePayload).filter((payload): payload is string => payload !== undefined).join("\n");
    if (returns.length < 2 || !texts.includes('"variant":"original"') || !texts.includes('"variant":"duplicate"')) {
      throw new Error("duplicate-reply capture must contain original and duplicate Return publications");
    }
  } else if (scenarioId === "late-reply") {
    const gaveUp = application.find((entry) => entry.state === "gave-up")?.at;
    const lateReturn = capture.find((record) => record.mqtt?.topic?.includes("/RTN/"));
    if (!gaveUp || !lateReturn?.capturedAt || Date.parse(lateReturn.capturedAt) <= Date.parse(gaveUp)) {
      throw new Error("late-reply capture must show a Return after the application deadline");
    }
  } else if (scenarioId === "reconnect-resubscribe" || scenarioId === "broker-restart" || scenarioId === "clean-session") {
    const hasProbe = capture.some((record) => {
      if (!record.mqtt?.topic?.includes("/ADV/")) return false;
      const payload = decodePayload(record);
      return payload?.includes("com.coaty.test.WireFixture") ?? false;
    });
    if (!hasProbe) throw new Error(`${scenarioId} capture is missing the post-reconnect CoatyJS probe`);
  }
}

function parseJSONLines<T>(path: string): T[] {
  const lines = readFileSync(path, "utf8").split(/\r?\n/).filter((line) => line.trim().length > 0);
  return lines.map((line, index) => {
    try {
      return JSON.parse(line) as T;
    } catch (error) {
      throw new Error(`${path}:${index + 1} is not JSON: ${error instanceof Error ? error.message : String(error)}`);
    }
  });
}

function decodePayload(record: CaptureRecord): string | undefined {
  if (record.payload?.encoding !== "base64" || !record.payload.bytes) return undefined;
  try {
    return Buffer.from(record.payload.bytes, "base64").toString("utf8");
  } catch {
    return undefined;
  }
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
