// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { createHash } from "crypto";
import { readdirSync, readFileSync, writeFileSync } from "fs";
import { basename, join, resolve } from "path";

interface CaptureRecord {
  format: string;
  producer: { implementation: string; version: string };
  scenario: string;
  sequence: number;
}

interface CaptureManifestEntry {
  file: string;
  sha256: string;
  recordCount: number;
  producer: CaptureRecord["producer"];
  scenario: string;
}

export interface CaptureManifest {
  format: "coaty-wire-manifest/v1";
  captures: CaptureManifestEntry[];
}

/** Build a deterministic manifest for the JSONL captures in a directory. */
export function buildManifest(directory: string): CaptureManifest {
  const captures = readdirSync(directory)
    .filter((file) => file.endsWith(".jsonl"))
    .sort()
    .map((file) => {
      const path = join(directory, file);
      const bytes = readFileSync(path);
      const records = bytes.toString("utf8")
        .split("\n")
        .filter((line) => line.trim().length > 0)
        .map((line, index) => parseRecord(line, file, index + 1));

      if (records.length === 0) {
        throw new Error(`${file}: capture contains no records`);
      }

      const first = records[0]!;
      return {
        file: basename(file),
        sha256: createHash("sha256").update(bytes).digest("hex"),
        recordCount: records.length,
        producer: first.producer,
        scenario: first.scenario,
      };
    });

  if (captures.length === 0) {
    throw new Error(`no JSONL captures found in ${directory}`);
  }

  return { format: "coaty-wire-manifest/v1", captures };
}

/** Write a manifest atomically so readers never observe a partial document. */
export function writeManifest(directory: string, output: string): void {
  const manifest = JSON.stringify(buildManifest(resolve(directory)), null, 2) + "\n";
  const destination = resolve(output);
  writeFileSync(destination, manifest, "utf8");
}

function parseRecord(line: string, file: string, sequence: number): CaptureRecord {
  let record: unknown;
  try {
    record = JSON.parse(line);
  } catch (error) {
    throw new Error(`${file}: invalid JSON on record ${sequence}: ${String(error)}`);
  }

  if (!isCaptureRecord(record)) {
    throw new Error(`${file}: invalid capture record ${sequence}`);
  }
  if (record.format !== "coaty-wire-capture/v1") {
    throw new Error(`${file}: unsupported capture format ${record.format}`);
  }
  if (record.sequence !== sequence) {
    throw new Error(`${file}: expected sequence ${sequence}, got ${record.sequence}`);
  }
  return record;
}

function isCaptureRecord(value: unknown): value is CaptureRecord {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Partial<CaptureRecord>;
  return typeof record.format === "string"
    && typeof record.scenario === "string"
    && typeof record.sequence === "number"
    && typeof record.producer === "object"
    && record.producer !== null
    && typeof record.producer.implementation === "string"
    && typeof record.producer.version === "string";
}
