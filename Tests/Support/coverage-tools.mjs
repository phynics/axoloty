// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export function normalizeSourcePath(filename) {
  const marker = "/Source/";
  const index = filename.lastIndexOf(marker);
  return index < 0 ? null : filename.slice(index + 1);
}

export function extractCoverage(document) {
  const files = {};
  for (const bundle of document.data ?? []) {
    for (const entry of bundle.files ?? []) {
      const sourcePath = normalizeSourcePath(entry.filename ?? "");
      if (!sourcePath) continue;
      const lines = entry.summary?.lines ?? {};
      files[sourcePath] = { count: Number(lines.count ?? 0), covered: Number(lines.covered ?? 0) };
    }
  }
  return files;
}

export function aggregate(files) {
  const values = Object.values(files);
  const covered = values.reduce((sum, entry) => sum + entry.covered, 0);
  const count = values.reduce((sum, entry) => sum + entry.count, 0);
  return { covered, count, percent: count ? 100 * covered / count : 0 };
}

export function evaluateCoverage(files, baseline, maxDrop = 1) {
  const current = aggregate(files).percent;
  const baselinePercent = Number(baseline._aggregate?.percent ?? aggregate(baseline.files ?? {}).percent);
  const drop = baselinePercent - current;
  return drop > maxDrop
    ? [`aggregate coverage dropped from ${baselinePercent.toFixed(2)}% to ${current.toFixed(2)}% (${drop.toFixed(2)}pp exceeds ${maxDrop.toFixed(2)}pp)`]
    : [];
}

export function writeCoverageReport(files, outputPath) {
  const summary = aggregate(files);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const sortedFiles = Object.fromEntries(Object.entries(files).sort(([left], [right]) => left.localeCompare(right)));
  fs.writeFileSync(outputPath, `${JSON.stringify({ schemaVersion: 1, _aggregate: { ...summary, percent: rounded(summary.percent, 4) }, files: sortedFiles }, null, 2)}\n`);
  fs.writeFileSync(outputPath.replace(/\.[^.]+$/, ".txt"), `Axoloty source coverage: ${summary.covered}/${summary.count} lines (${summary.percent.toFixed(2)}%)\nFiles measured: ${Object.keys(files).length}\n`);
}

export function extractLineCoverage(document) {
  if (!Array.isArray(document.data)) throw new Error("LLVM coverage export data must be an array");
  const files = {};
  for (const bundle of document.data) {
    for (const entry of bundle.files ?? []) {
      const sourcePath = normalizeSourcePath(entry.filename ?? "");
      if (!sourcePath) continue;
      const lines = {};
      for (const segment of entry.segments ?? []) {
        if (segment.length < 4) continue;
        const [line, , count, hasCount, , isGap = false] = segment;
        if (hasCount && !isGap) lines[line] = Boolean(lines[line]) || count > 0;
      }
      files[sourcePath] = lines;
    }
  }
  return files;
}

export function parseChangedLines(diffText) {
  const changed = {};
  let sourcePath = null;
  let currentLine = null;
  for (const line of diffText.split(/\r?\n/)) {
    if (line.startsWith("+++ b/")) {
      sourcePath = line.slice(6);
      if (!sourcePath.startsWith("Source/")) sourcePath = null;
      currentLine = null;
      continue;
    }
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.exec(line);
    if (hunk) { currentLine = Number(hunk[1]); continue; }
    if (!sourcePath || currentLine === null || line.startsWith("\\")) continue;
    if (line.startsWith("+")) {
      (changed[sourcePath] ??= new Set()).add(currentLine++);
    } else if (!line.startsWith("-")) currentLine++;
  }
  return changed;
}

export function summarizeCoverage(document, diffText, baseline) {
  const lineFiles = extractLineCoverage(document);
  const currentFiles = extractCoverage(document);
  let changedCovered = 0;
  let changedCount = 0;
  const uncovered = [];
  for (const [sourcePath, changedLines] of Object.entries(parseChangedLines(diffText))) {
    const executable = [...changedLines].filter(line => lineFiles[sourcePath]?.[line] !== undefined);
    changedCount += executable.length;
    changedCovered += executable.filter(line => lineFiles[sourcePath][line]).length;
    uncovered.push(...executable.filter(line => !lineFiles[sourcePath][line]).map(line => [sourcePath, line]));
  }
  const regressions = [];
  for (const [sourcePath, baselineEntry] of Object.entries(baseline.files ?? {})) {
    const current = currentFiles[sourcePath];
    if (!current?.count) continue;
    const baselinePercent = percent(baselineEntry.covered, baselineEntry.count);
    const currentPercent = percent(current.covered, current.count);
    if (currentPercent < baselinePercent) regressions.push({ path: sourcePath, baseline: baselinePercent, current: currentPercent, delta: rounded(currentPercent - baselinePercent, 2) });
  }
  regressions.sort((left, right) => left.delta - right.delta || left.path.localeCompare(right.path));
  const aggregateSummary = aggregate(currentFiles);
  return {
    aggregate: { covered: aggregateSummary.covered, count: aggregateSummary.count, percent: rounded(aggregateSummary.percent, 2) },
    baseline: Number(baseline._aggregate?.percent ?? 0),
    changed: { covered: changedCovered, count: changedCount, percent: percent(changedCovered, changedCount) },
    regressions: regressions.slice(0, 10),
    uncovered: uncovered.sort(([leftPath, leftLine], [rightPath, rightLine]) => leftPath.localeCompare(rightPath) || leftLine - rightLine),
  };
}

export function renderCoverageMarkdown(summary) {
  const aggregateSummary = summary.aggregate;
  const changed = summary.changed;
  const lines = [
    "## Source coverage", "", "| Metric | Value |", "| --- | ---: |",
    `| Aggregate | ${aggregateSummary.covered}/${aggregateSummary.count} (${aggregateSummary.percent.toFixed(2)}%) |`,
    `| Baseline delta | ${(aggregateSummary.percent - summary.baseline).toFixed(2).replace(/^(?!-)/, "+")} percentage points |`,
    `| Changed executable lines | ${changed.covered}/${changed.count} (${changed.percent.toFixed(2)}%) |`,
  ];
  if (summary.regressions.length) {
    lines.push("", "### Largest file-level decreases", "");
    for (const entry of summary.regressions) lines.push(`- \`${entry.path}\`: ${entry.current.toFixed(2)}% (${entry.delta.toFixed(2).replace(/^(?!-)/, "+")} pp)`);
  }
  if (summary.uncovered.length) lines.push("", `Informational warnings: ${summary.uncovered.length} changed executable lines are uncovered.`);
  return `${lines.join("\n")}\n`;
}

function percent(covered, count) { return count ? rounded(100 * covered / count, 2) : 0; }
function rounded(value, digits) { return Number(value.toFixed(digits)); }
function readJSON(file) { return JSON.parse(fs.readFileSync(file, "utf8")); }

export function main(args = process.argv.slice(2)) {
  try {
    const [command, ...rest] = args;
    if (command === "summary") {
      const [exportPath, flag, reportPath] = rest;
      const files = extractCoverage(readJSON(exportPath));
      if (flag === "--report" && reportPath) writeCoverageReport(files, reportPath);
      const summary = aggregate(files);
      console.log(`Axoloty source coverage: ${summary.covered}/${summary.count} lines (${summary.percent.toFixed(2)}%)`);
      console.log(`Files measured: ${Object.keys(files).length}`);
      return 0;
    }
    if (command === "check") {
      const [exportPath, baselinePath = "Tests/Support/coverage-baseline.json"] = rest;
      const files = extractCoverage(readJSON(exportPath));
      const baseline = readJSON(baselinePath);
      const errors = evaluateCoverage(files, baseline);
      if (errors.length) { for (const error of errors) console.error(`coverage ratchet: ${error}`); return 1; }
      console.log(`PASS: source coverage ${aggregate(files).percent.toFixed(2)}% (baseline ${Number(baseline._aggregate?.percent ?? 0).toFixed(2)}%, ratchet within policy)`);
      return 0;
    }
    if (command === "report") {
      const [exportPath, diffPath, baselinePath = "Tests/Support/coverage-baseline.json"] = rest;
      const summary = summarizeCoverage(readJSON(exportPath), diffPath ? fs.readFileSync(diffPath, "utf8") : "", readJSON(baselinePath));
      const markdown = renderCoverageMarkdown(summary);
      process.stdout.write(markdown);
      if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, markdown);
      if (process.env.GITHUB_ACTIONS === "true") for (const [sourcePath, line] of summary.uncovered.slice(0, 20)) console.log(`::warning file=${sourcePath},line=${line}::Changed executable line is not covered`);
      return 0;
    }
    console.error("usage: coverage-tools.mjs <summary|check|report> ...");
    return 2;
  } catch (error) {
    console.error(`coverage tooling error: ${error.message}`);
    return 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
