// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";

export function percentile(values, percent) {
  if (!values.length) return 0;
  const index = (values.length - 1) * percent / 100;
  const lower = Math.floor(index);
  const upper = Math.min(lower + 1, values.length - 1);
  return lower === upper ? values[lower] : values[lower] + (values[upper] - values[lower]) * (index - lower);
}

export function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = (sorted.length - 1) / 2;
  return sorted.length % 2 ? sorted[Math.floor(middle)] : (sorted[middle] + sorted[middle + 1]) / 2;
}

export function mad(values) {
  return values.length ? median(values.map(value => Math.abs(value - median(values)))) : 0;
}

function samples(run, caseId, operation) {
  const entry = run.cases.find(item => item.caseId === caseId).operations[operation];
  return [...entry.samplesNs].sort((left, right) => left - right);
}

export function aggregate(directory) {
  const runs = Array.from({ length: 5 }, (_, index) => JSON.parse(fs.readFileSync(`${directory}/run-${index + 1}.json`, "utf8")));
  const cases = runs[0].cases.map(input => {
    const operations = {};
    for (const [name, operation] of Object.entries(input.operations ?? {})) {
      const p50 = runs.map(run => percentile(samples(run, input.caseId, name), 50));
      const p95 = runs.map(run => percentile(samples(run, input.caseId, name), 95));
      operations[name] = { p50ns: Math.trunc(median(p50)), p95ns: Math.trunc(median(p95)), batchSize: operation.batchSize ?? 1 };
    }
    return { caseId: input.caseId, family: input.family, sizeClass: input.sizeClass, operations };
  });
  const noisy = [];
  for (const entry of cases) {
    for (const [name, operation] of Object.entries(entry.operations)) {
      const p50 = runs.map(run => percentile(samples(run, entry.caseId, name), 50));
      if (operation.p50ns > 0 && mad(p50) / operation.p50ns > 0.05) noisy.push(`${entry.caseId}.${name}`);
    }
  }
  return { environment: runs[0].environment ?? {}, cpuGovernor: process.env.CPU_GOVERNOR ?? "unknown", cases, ...(noisy.length ? { noisy } : {}) };
}

export function compare(current, baseline) {
  const currentHash = current.environment?.corpusHash ?? "";
  const baselineHash = baseline.environment?.corpusHash ?? "";
  if (!currentHash || !baselineHash || currentHash !== baselineHash) {
    return `MISMATCH: corpus hash differs (new=${currentHash}, base=${baselineHash})`;
  }
  const currentCases = Object.fromEntries((current.cases ?? []).map(entry => [entry.caseId, entry]));
  const baselineCases = Object.fromEntries((baseline.cases ?? []).map(entry => [entry.caseId, entry]));
  const differences = [];
  for (const caseId of new Set([...Object.keys(currentCases), ...Object.keys(baselineCases)])) {
    const currentCase = currentCases[caseId];
    const baselineCase = baselineCases[caseId];
    if (!currentCase || !baselineCase) {
      differences.push(`  ${currentCase ? "+" : "-"} ${caseId}`);
      continue;
    }
    for (const operation of new Set([...Object.keys(currentCase.operations), ...Object.keys(baselineCase.operations)])) {
      const currentOperation = currentCase.operations[operation];
      const baselineOperation = baselineCase.operations[operation];
      if (!currentOperation || !baselineOperation) {
        differences.push(`  ${currentOperation ? "+" : "-"} ${caseId}.${operation}`);
        continue;
      }
      for (const field of ["p50ns", "p95ns"]) {
        if (baselineOperation[field] > 0 && Math.abs(currentOperation[field] - baselineOperation[field]) / baselineOperation[field] > 0.1) {
          differences.push(`  ~ ${caseId}.${operation} ${field}: ${baselineOperation[field]} -> ${currentOperation[field]}`);
        }
      }
    }
  }
  return differences.length ? `BASELINE DRIFT detected:\n${differences.join("\n")}` : "MATCH";
}
