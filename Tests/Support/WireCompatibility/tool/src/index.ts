#!/usr/bin/env node
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { runCapture, type CaptureOptions } from "./capture.js";
import { writeManifest } from "./manifest.js";
import { writeLifecycleManifest } from "./lifecycle.js";
import { controlProxy, runProxy, type ProxyOptions } from "./proxy.js";
import { writeLegacyManifest } from "./legacy.js";
import { waitForFile } from "./atomic.js";
import {
  decodePayload,
  encodeCbor,
  encodeJSONText,
  parseDiagnostic,
} from "./cbor.js";
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const USAGE = `Usage: axoloty-wire <command> [options]

Commands:
  capture <topic-filter> <out.jsonl>   Passively capture MQTT traffic to JSONL.
  run <scenario>                       Start pinned CoatyJS 2.4.0 reference
                                        agent(s), drive a named scenario, and
                                        capture wire traffic.
  manifest <captures-dir> <out.json>   Build a manifest from captured JSONL files.
  lifecycle-manifest <scenario> <out.json>  Write lifecycle evidence metadata.
  proxy                              Run the lifecycle TCP proxy.
  proxy-control                       Send sever or restore to the lifecycle proxy.
  legacy-manifest <capture> <out>   Write a macOS legacy provenance manifest.
  decode <capture.jsonl>            Render captured JSON or CBOR payloads as
                                    RFC 8949 diagnostic notation (or JSON).
  encode                            Encode JSON or diagnostic notation as
                                    deterministic CBOR bytes.

capture options:
  --host <host>                  Broker hostname (default: 127.0.0.1)
  --port <port>                  Broker port (default: 1883)
  --qos <0|1>                    Subscription QoS (default: 1)
  --producer <name>              Producer implementation (required)
  --producer-version <version>   Producer version (required)
  --scenario <name>              Scenario name (required)
  --normalization-profile <name>  Normalization profile (default: coaty-v1)
  --count <n>                    Stop after N publications; 0 = unlimited (default: 0)
  --timeout <seconds>            Connect/handshake timeout (default: 10)
  --ready-file <path>            Atomically create this file after subscription is accepted

The capture/run subcommands produce provenance-bearing JSONL captures.
Semantic verification of captures is done Swift-side (#123).
run options:
  --runner-command <command>       Local scenario command to run after capture is ready.
  --topic-filter <filter>          Capture topic filter (default: #).
  --output <file>                  Capture output path.
  --producer <name>                Producer implementation.
  --producer-version <version>     Producer version.
  --ready-file <path>              Readiness marker passed to the capture process.
decode options:
  --record <n>                     Decode only the record with this sequence number.
  --topic <topic>                  Decode only records whose topic equals this value.
  --format <diagnostic|json>       Output view (default: diagnostic).
encode options:
  --json <text>                    JSON document to encode.
  --json-file <path>               File containing a JSON document to encode.
  --diagnostic <text>              RFC 8949 diagnostic notation to encode.
  --base64                         Emit base64 instead of hexadecimal.
  --out <path>                     Write bytes to a file instead of stdout.`;

function main(): void {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const rest = argv.slice(1);

  switch (cmd) {
    case "capture":
      runCaptureCommand(rest);
      break;
    case "run":
      runScenarioCommand(rest);
      break;
    case "manifest":
      runManifestCommand(rest);
      break;
    case "lifecycle-manifest":
      runLifecycleManifestCommand(rest);
      break;
    case "proxy":
      runProxyCommand(rest);
      break;
    case "proxy-control":
      runProxyControlCommand(rest);
      break;
    case "legacy-manifest":
      runLegacyManifestCommand(rest);
      break;
    case "decode":
      runDecodeCommand(rest);
      break;
    case "encode":
      runEncodeCommand(rest);
      break;
    case undefined:
    case "-h":
    case "--help":
      process.stdout.write(USAGE + "\n");
      break;
    default:
      process.stderr.write(`Unknown command: ${cmd}\n\n`);
      process.stdout.write(USAGE + "\n");
      process.exit(1);
  }
}

function runCaptureCommand(args: string[]): void {
  const opts = parseCaptureArgs(args);
  runCapture(opts).then(
    () => { process.exit(0); },
    (err: unknown) => {
      process.stderr.write(`capture failed: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(1);
    },
  );
}

function runScenarioCommand(args: string[]): void {
  const scenario = args[0];
  const runner = option(args, "--runner-command");
  const topicFilter = option(args, "--topic-filter") ?? "#";
  const output = option(args, "--output");
  const producer = option(args, "--producer");
  const producerVersion = option(args, "--producer-version");
  const readyFile = option(args, "--ready-file");
  if (!scenario || !runner || !output || !producer || !producerVersion) {
    process.stderr.write("usage: axoloty-wire run SCENARIO --runner-command COMMAND --output FILE --producer NAME --producer-version VERSION [--topic-filter FILTER]\n");
    process.exit(2);
  }

  runScenarioOrdered({ scenario, runner, topicFilter, output, producer, producerVersion, readyFile }).catch(
    (error: unknown) => {
      process.stderr.write(`run failed: ${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    },
  );
}

async function runScenarioOrdered(opts: {
  scenario: string;
  runner: string;
  topicFilter: string;
  output: string;
  producer: string;
  producerVersion: string;
  readyFile?: string;
}): Promise<void> {
  const { scenario, runner, topicFilter, output, producer, producerVersion, readyFile } = opts;
  const captureArgs = ["capture", topicFilter, output, "--producer", producer, "--producer-version", producerVersion, "--scenario", scenario];
  if (readyFile) captureArgs.push("--ready-file", readyFile);
  const capture = spawn(process.execPath, [process.argv[1]!, ...captureArgs], { stdio: "inherit" });
  if (readyFile) {
    try {
      await waitForFile(readyFile, 30);
    } catch (error) {
      capture.kill("SIGTERM");
      throw new Error(`capture did not become ready: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  const scenarioProcess = spawn(runner, { shell: true, stdio: "inherit", env: { ...process.env, SCENARIO: scenario } });
  scenarioProcess.once("error", (error) => { process.stderr.write(`scenario failed: ${error.message}\n`); capture.kill("SIGTERM"); process.exit(1); });
  scenarioProcess.once("close", (code, signal) => {
    capture.kill("SIGTERM");
    if (code !== 0 || signal) process.exit(code ?? 1);
  });
}

function runManifestCommand(args: string[]): void {
  const directory = args[0];
  const output = args[1];
  if (!directory || !output || args.length !== 2) {
    process.stderr.write("usage: axoloty-wire manifest <captures-dir> <out.json>\n");
    process.exit(2);
  }

  try {
    writeManifest(directory, output);
  } catch (err: unknown) {
    process.stderr.write(`manifest failed: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exit(1);
  }
}

function runLifecycleManifestCommand(args: string[]): void {
  const scenario = args[0];
  const output = args[1];
  const applicationLog = option(args, "--application-log");
  const capture = option(args, "--capture");
  const unsupportedReason = option(args, "--unsupported");
  if (!scenario || !output || args.length < 2) {
    process.stderr.write("usage: axoloty-wire lifecycle-manifest <scenario> <out.json> [--application-log FILE --capture FILE] [--unsupported REASON]\n");
    process.exit(2);
  }
  try { writeLifecycleManifest(scenario, applicationLog, capture, output, unsupportedReason); }
  catch (err: unknown) { process.stderr.write(`lifecycle manifest failed: ${err instanceof Error ? err.message : String(err)}\n`); process.exit(1); }
}

function runProxyCommand(args: string[]): void {
  const required = (name: string): string => {
    const value = option(args, name);
    if (!value) { process.stderr.write(`error: ${name} requires a value\n`); process.exit(2); }
    return value;
  };
  const options: ProxyOptions = {
    listenPort: Number(required("--listen-port")),
    brokerHost: option(args, "--broker-host") ?? "127.0.0.1",
    brokerPort: Number(option(args, "--broker-port") ?? "1883"),
    controlPort: Number(required("--control-port")),
    connackLog: required("--connack-log"),
    readyFile: required("--ready-file"),
  };
  runProxy(options).catch((err: unknown) => { process.stderr.write(`proxy failed: ${err instanceof Error ? err.message : String(err)}\n`); process.exit(1); });
}

function runProxyControlCommand(args: string[]): void {
  const command = option(args, "--command");
  if (command !== "sever" && command !== "restore") {
    process.stderr.write("error: --command must be sever or restore\n");
    process.exit(2);
  }
  controlProxy(option(args, "--host") ?? "127.0.0.1", Number(option(args, "--port") ?? "18884"), command)
    .catch((err: unknown) => { process.stderr.write(`proxy control failed: ${err instanceof Error ? err.message : String(err)}\n`); process.exit(1); });
}

function runLegacyManifestCommand(args: string[]): void {
  const capture = args[0];
  const output = args[1];
  const version = option(args, "--version");
  const sourceCommit = option(args, "--source-commit");
  const scenario = option(args, "--scenario");
  if (!capture || !output || !version || !sourceCommit || !scenario) {
    process.stderr.write("usage: axoloty-wire legacy-manifest <capture> <out> --version VERSION --source-commit SHA --scenario NAME\n");
    process.exit(2);
  }
  try { writeLegacyManifest(capture, output, version, sourceCommit, scenario); }
  catch (err: unknown) { process.stderr.write(`legacy manifest failed: ${err instanceof Error ? err.message : String(err)}\n`); process.exit(1); }
}

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function positionalArgs(args: string[], valueOptions: ReadonlySet<string>): string[] {
  const positional: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!;
    if (valueOptions.has(arg)) {
      index += 1;
      continue;
    }
    if (!arg.startsWith("--")) positional.push(arg);
  }
  return positional;
}

function payloadBytes(record: unknown): Buffer | undefined {
  if (typeof record !== "object" || record === null) return undefined;
  const payload = (record as { payload?: unknown }).payload;
  if (typeof payload !== "object" || payload === null) return undefined;
  const { encoding, bytes } = payload as { encoding?: unknown; bytes?: unknown };
  if (typeof bytes !== "string") return undefined;
  if (encoding === "hex") return Buffer.from(bytes, "hex");
  if (encoding === "base64") return Buffer.from(bytes, "base64");
  process.stderr.write(`decode: skipping payload with unsupported encoding ${JSON.stringify(encoding)}\n`);
  return undefined;
}

function runDecodeCommand(args: string[]): void {
  const positional = positionalArgs(args, new Set(["--record", "--topic", "--format"]));
  const capture = positional[0];
  const record = option(args, "--record");
  const topic = option(args, "--topic");
  const format = option(args, "--format") ?? "diagnostic";
  if (!capture || (format !== "diagnostic" && format !== "json")) {
    process.stderr.write("usage: axoloty-wire decode <capture.jsonl> [--record N] [--topic TOPIC] [--format diagnostic|json]\n");
    process.exit(2);
  }

  let lines: string[];
  try {
    lines = readFileSync(capture, "utf8").split("\n").filter((line) => line.trim().length > 0);
  } catch (error) {
    process.stderr.write(`decode failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }

  const output: string[] = [];
  for (const line of lines) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    const sequence = typeof (parsed as { sequence?: unknown }).sequence === "number"
      ? (parsed as { sequence: number }).sequence
      : null;
    const recordTopic = typeof (parsed as { mqtt?: { topic?: unknown } }).mqtt?.topic === "string"
      ? (parsed as { mqtt: { topic: string } }).mqtt.topic
      : null;
    if (record !== undefined && String(sequence) !== record) continue;
    if (topic !== undefined && recordTopic !== topic) continue;
    const bytes = payloadBytes(parsed);
    if (bytes === undefined) continue;
    const decoded = decodePayload(bytes);
    const entry: Record<string, unknown> = { sequence, topic: recordTopic, format: decoded.format };
    if (format === "json") entry.json = decoded.json ?? null;
    else entry.diagnostic = decoded.diagnostic;
    output.push(JSON.stringify(entry));
  }
  if (output.length > 0) process.stdout.write(output.join("\n") + "\n");
}

function runEncodeCommand(args: string[]): void {
  const json = option(args, "--json");
  const jsonFile = option(args, "--json-file");
  const diagnostic = option(args, "--diagnostic");
  const out = option(args, "--out");
  const base64 = args.includes("--base64");
  const sources = [json, jsonFile, diagnostic].filter((value) => value !== undefined);
  if (sources.length !== 1) {
    process.stderr.write("usage: axoloty-wire encode (--json TEXT | --json-file FILE | --diagnostic TEXT) [--base64] [--out FILE]\n");
    process.exit(2);
  }

  let bytes: Buffer;
  try {
    if (jsonFile !== undefined) bytes = encodeJSONText(readFileSync(jsonFile, "utf8"));
    else if (json !== undefined) bytes = encodeJSONText(json);
    else bytes = encodeCbor(parseDiagnostic(diagnostic!));
  } catch (error) {
    process.stderr.write(`encode failed: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }

  if (out !== undefined) {
    try {
      writeFileSync(out, bytes);
    } catch (error) {
      process.stderr.write(`encode failed: ${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    }
    return;
  }
  process.stdout.write((base64 ? bytes.toString("base64") : bytes.toString("hex")) + "\n");
}

function parseCaptureArgs(args: string[]): CaptureOptions {
  let topicFilter: string | undefined;
  let output: string | undefined;
  let host = "127.0.0.1";
  let port = 1883;
  let qos: 0 | 1 = 1;
  let producer: string | undefined;
  let producerVersion: string | undefined;
  let scenario: string | undefined;
  let normalizationProfile = "coaty-v1";
  let count = 0;
  let timeout = 10;
  let readyFile: string | undefined;

  const positional: string[] = [];

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    const next = (): string => {
      const val = args[++i];
      if (val === undefined) {
        process.stderr.write(`error: ${arg} requires a value\n`);
        process.exit(2);
      }
      return val;
    };

    switch (arg) {
      case "--host": host = next(); break;
      case "--port": port = parseInt(next(), 10); break;
      case "--qos": {
        const q = parseInt(next(), 10);
        if (q !== 0 && q !== 1) {
          process.stderr.write(`error: --qos must be 0 or 1\n`);
          process.exit(2);
        }
        qos = q;
        break;
      }
      case "--producer": producer = next(); break;
      case "--producer-version": producerVersion = next(); break;
      case "--scenario": scenario = next(); break;
      case "--normalization-profile": normalizationProfile = next(); break;
      case "--count": count = parseInt(next(), 10); break;
      case "--timeout": timeout = parseFloat(next()); break;
      case "--ready-file": readyFile = next(); break;
      default:
        if (arg.startsWith("--")) {
          process.stderr.write(`error: unknown option ${arg}\n`);
          process.exit(2);
        }
        positional.push(arg);
        break;
    }
  }

  topicFilter = positional[0];
  output = positional[1];

  if (!topicFilter) {
    process.stderr.write("error: topic-filter is required (positional arg 1)\n");
    process.exit(2);
  }
  if (!output) {
    process.stderr.write("error: out.jsonl is required (positional arg 2)\n");
    process.exit(2);
  }
  if (!producer) {
    process.stderr.write("error: --producer is required\n");
    process.exit(2);
  }
  if (!producerVersion) {
    process.stderr.write("error: --producer-version is required\n");
    process.exit(2);
  }
  if (!scenario) {
    process.stderr.write("error: --scenario is required\n");
    process.exit(2);
  }

  return {
    topicFilter,
    output,
    host,
    port,
    qos,
    producer,
    producerVersion,
    scenario,
    normalizationProfile,
    count,
    timeout,
    readyFile,
  };
}

main();
