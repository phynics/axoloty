// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { arch, platform } from "node:process";

/** Write the provenance manifest for a macOS legacy CoatySwift capture. */
export function writeLegacyManifest(capture: string, output: string, version: string, sourceCommit: string, scenario: string): void {
  if (platform !== "darwin") throw new Error("legacy reference manifests may only be generated on macOS");
  const bytes = readFileSync(capture);
  const command = (name: string, args: string[]) => execFileSync(name, args, { encoding: "utf8" }).trim().replace(/\n/g, " ");
  const value = {
    format: "coaty-legacy-capture-manifest/v1",
    capture: { file: capture.split("/").pop() ?? capture, sha256: createHash("sha256").update(bytes).digest("hex"), recordCount: bytes.toString("utf8").split(/\r?\n/).filter(Boolean).length },
    producer: { implementation: "coatyswift-legacy", version },
    source: { repository: "https://github.com/coatyio/coaty-swift.git", commit: sourceCommit },
    runner: { os: "macOS", architecture: arch, swiftVersion: command("swift", ["--version"]), xcodeVersion: command("xcodebuild", ["-version"]), generatedAt: new Date().toISOString() },
    scenario,
  };
  writeFileSync(output, JSON.stringify(value, null, 2) + "\n", "utf8");
}
