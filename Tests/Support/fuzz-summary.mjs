// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";
import path from "node:path";

export function latestManifest(root = ".testing/fuzz") {
  const manifests = fs.readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && entry.name.startsWith("fuzz-"))
    .map(entry => path.join(root, entry.name, "manifest.json"))
    .filter(file => fs.existsSync(file))
    .sort();
  return manifests.at(-1) ?? null;
}

export function summaryMarkdown(manifest) {
  return [
    "## Fuzz Campaign\n",
    `- Status: \`${manifest.status ?? "unknown"}\`\n`,
    `- Seeds: \`${(manifest.seeds ?? []).join(",")}\`\n`,
    `- Iterations: \`${manifest.iterations}\`\n`,
    `- Repetitions: \`${manifest.repetitions}\`\n`,
    `- Duration: \`${manifest.durationSeconds}s\`\n`,
    `- Failed cases: \`${manifest.failedCases}\`\n`,
  ].join("");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const manifest = latestManifest(process.argv[2] ?? ".testing/fuzz");
  if (!manifest) {
    console.log("No fuzz manifest was produced.");
  } else {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summaryMarkdown(JSON.parse(fs.readFileSync(manifest, "utf8"))));
  }
}
