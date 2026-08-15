// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { fileURLToPath } from "node:url";
import { atomicWriteFileSync } from "./atomic.js";

const CLI_JAVASCRIPT = fileURLToPath(new URL("./index.js", import.meta.url));

function runCLI(args: string[]): { child: ChildProcess; stderr: () => Promise<string> } {
  const child = spawn(process.execPath, [CLI_JAVASCRIPT, ...args], { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  child.stderr!.on("data", (data) => { stderr += data.toString(); });
  const close = new Promise<number | null>((resolve) => child.on("close", (code) => resolve(code)));
  return {
    child,
    stderr: async () => { await close; return stderr; },
  };
}

/**
 * The `run` subcommand must start the scenario runner only after capture
 * readiness. We deterministically model the race: the ready marker does not
 * exist when `run` is launched, appears a short time later while `run` is
 * waiting, and the runner (spawned only after readiness) must observe it. If
 * the command raced ahead of readiness, the runner would be launched before
 * the marker existed and would exit with a distinct code.
 */
test("run starts the scenario only after capture readiness", async () => {
  const directory = mkdtempSync(join(tmpdir(), "axoloty-run-order-"));
  const readyFile = join(directory, "capture.ready");
  const output = join(directory, "capture.jsonl");
  const runnerSeen = join(directory, "runner.saw.ready");
  writeFileSync(output, "placeholder\n");

  const sawReady = "require('fs').existsSync(" + JSON.stringify(readyFile) + ")" +
    "?require('fs').writeFileSync(" + JSON.stringify(runnerSeen) + ",'yes')" +
    ":process.exit(66)";
  const runner = "node -e " + JSON.stringify(sawReady);

  const { child } = runCLI(["run", "advertise",
    "--runner-command", runner,
    "--topic-filter", "#",
    "--output", output,
    "--producer", "coatyjs",
    "--producer-version", "2.4.0",
    "--ready-file", readyFile,
  ]);

  // The readiness marker appears only while `run` is waiting on it. A racing
  // implementation would have started the runner before this write.
  setTimeout(() => atomicWriteFileSync(readyFile, "subscribed\n"), 50);

  await new Promise<number | null>((resolve) => child.on("close", resolve));

  assert.equal(existsSync(runnerSeen), true, "runner must have executed only after readiness marker appeared");
  assert.equal(readFileSync(runnerSeen, "utf8"), "yes");
});