// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/**
 * Independent verification of the frozen golden corpus.
 *
 * Every `.cbor` golden is decoded with `cbor-x`, a decoder that shares no code
 * with Axoloty, and deep-compared against the paired `.json` golden. CBOR tag
 * 37 UUID byte strings are normalized to the canonical hyphenated text form.
 * Object key order is ignored; array order is significant.
 */

import fs from "node:fs";
import path from "node:path";

import { Decoder } from "cbor-x";

import type { GoldenManifest } from "./goldenCorpus.js";

interface TagLike {
  tag: number;
  value: Uint8Array;
}

/** Decode `goldenDir` and return one human-readable message per mismatch. */
export function verifyGoldenCorpus(goldenDir: string): string[] {
  const problems: string[] = [];
  const manifestPath = path.join(goldenDir, "manifest.json");
  if (!fs.existsSync(manifestPath)) return [`missing manifest: ${manifestPath}`];
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) as GoldenManifest;
  if (!Array.isArray(manifest.cases) || manifest.cases.length === 0) {
    return ["manifest.json declares no golden cases"];
  }
  const decoder = new Decoder({ useRecords: false, mapsAsObjects: true, tagUint8Array: false });
  for (const goldenCase of manifest.cases) {
    const expected = JSON.parse(fs.readFileSync(path.join(goldenDir, goldenCase.json), "utf8")) as unknown;
    let actual: unknown;
    try {
      actual = normalize(decoder.decode(fs.readFileSync(path.join(goldenDir, goldenCase.cbor)))) as unknown;
    } catch (error) {
      problems.push(`${goldenCase.id}: cbor-x failed to decode ${goldenCase.cbor}: ${(error as Error).message}`);
      continue;
    }
    compare(expected, actual, "", problems, goldenCase.id);
  }
  return problems;
}

function normalize(value: unknown): unknown {
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") return value;
  if (typeof value === "bigint") return Number(value);
  if (Array.isArray(value)) return value.map(normalize);
  if (value instanceof Uint8Array) return Buffer.from(value).toString("hex");
  if (isTag(value)) {
    if (value.tag === 37) return uuidFromBytes(value.value);
    return { tag: value.tag, value: normalize(value.value) };
  }
  if (typeof value === "object") {
    const source = value as Record<string, unknown>;
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(source)) result[key] = normalize(source[key]);
    return result;
  }
  return value;
}

function isTag(value: unknown): value is TagLike {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as TagLike).tag === "number" &&
    (value as TagLike).value instanceof Uint8Array
  );
}

function uuidFromBytes(bytes: Uint8Array): string {
  const hex = Buffer.from(bytes).toString("hex");
  if (hex.length !== 32) return `tag37:${hex}`;
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

function compare(
  expected: unknown,
  actual: unknown,
  pointer: string,
  problems: string[],
  caseId: string,
): void {
  const at = pointer || "/";
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) {
      problems.push(`${caseId}: ${at} expected array, got ${describe(actual)}`);
      return;
    }
    if (expected.length !== actual.length) {
      problems.push(`${caseId}: ${at} length ${actual.length} != ${expected.length}`);
      return;
    }
    expected.forEach((item, index) => compare(item, actual[index], `${pointer}/${index}`, problems, caseId));
    return;
  }
  if (expected !== null && typeof expected === "object") {
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) {
      problems.push(`${caseId}: ${at} expected object, got ${describe(actual)}`);
      return;
    }
    const expectedObject = expected as Record<string, unknown>;
    const actualObject = actual as Record<string, unknown>;
    const expectedKeys = Object.keys(expectedObject).sort();
    const actualKeys = Object.keys(actualObject).sort();
    if (expectedKeys.join("\u0000") !== actualKeys.join("\u0000")) {
      problems.push(`${caseId}: ${at} keys [${actualKeys.join(",")}] != [${expectedKeys.join(",")}]`);
      return;
    }
    for (const key of expectedKeys) {
      compare(expectedObject[key], actualObject[key], `${pointer}/${key}`, problems, caseId);
    }
    return;
  }
  if (!Object.is(expected, actual)) {
    problems.push(`${caseId}: ${at} ${describe(actual)} != ${describe(expected)}`);
  }
}

function describe(value: unknown): string {
  if (typeof value === "string") return JSON.stringify(value);
  if (value === null) return "null";
  return String(value);
}
