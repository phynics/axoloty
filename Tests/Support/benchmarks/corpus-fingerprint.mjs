// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const corpusDirectory = process.argv[2] ?? "Benchmarks/Corpus";
const manifest = fs.readFileSync(path.join(corpusDirectory, "manifest.json"));
const document = JSON.parse(manifest);
const hash = crypto.createHash("sha256");

for (const bytes of [
  manifest,
  ...document.cases.map(entry => fs.readFileSync(path.join(corpusDirectory, entry.payloadFile))),
]) {
  const length = Buffer.alloc(8);
  length.writeBigUInt64BE(BigInt(bytes.length));
  hash.update(length);
  hash.update(bytes);
}

process.stdout.write(`${hash.digest("hex")}\n`);
