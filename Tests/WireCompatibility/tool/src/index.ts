#!/usr/bin/env node
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { runCapture, type CaptureOptions } from "./capture.js";

const USAGE = `Usage: axoloty-wire <command> [options]

Commands:
  capture <topic-filter> <out.jsonl>   Passively capture MQTT traffic to JSONL.
  run <scenario>                       Start pinned CoatyJS 2.4.0 reference
                                        agent(s), drive a named scenario, and
                                        capture wire traffic.
  manifest <captures-dir> <out.json>   Build a manifest from captured JSONL files.

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
The run/manifest subcommands are not yet implemented.`;

function main(): void {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const rest = argv.slice(1);

  switch (cmd) {
    case "capture":
      runCaptureCommand(rest);
      break;
    case "run":
      notImplemented("run", rest);
      break;
    case "manifest":
      notImplemented("manifest", rest);
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

function notImplemented(command: string, args: string[]): never {
  process.stderr.write(
    `Not implemented yet: \`axoloty-wire ${command}${args.length > 0 ? " " + args.join(" ") : ""}\`.\n` +
      "This subcommand lands in a follow-up issue.\n",
  );
  process.exit(2);
}

main();
