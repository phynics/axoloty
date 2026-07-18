#!/usr/bin/env node
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

const USAGE = `Usage: axoloty-wire <command> [options]

Commands:
  capture <topic-filter> <out.jsonl>   Passively capture MQTT traffic to JSONL.
  run <scenario>                       Start pinned CoatyJS 2.4.0 reference
                                        agent(s), drive a named scenario, and
                                        capture wire traffic.
  manifest <captures-dir> <out.json>   Build a manifest from captured JSONL files.

This is the scaffold (#121): subcommand dispatch and help only. The
capture/run/manifest implementations land in follow-up issues; semantic
verification of captures stays Swift-side (#123).`;

function main(): void {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const rest = argv.slice(1);

  switch (cmd) {
    case "capture":
      notImplemented("capture", rest);
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

function notImplemented(command: string, args: string[]): never {
  process.stderr.write(
    `Not implemented yet (scaffold #121): \`axoloty-wire ${command}${args.length > 0 ? " " + args.join(" ") : ""}\`.\n` +
      "Functional capture/run/manifest land in follow-up issues.\n",
  );
  process.exit(2);
}

main();
