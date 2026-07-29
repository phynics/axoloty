// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import { fileURLToPath } from "node:url";

export const discardRule = "   *(.got .got.plt) /* TODO: GCC-382 */\n";
export const replacement = "   /* Swift UnicodeDataTables requires .got/.got.plt. */\n";

export function patchSwiftGOT(linkerScript) {
  const text = fs.readFileSync(linkerScript, "utf8");
  const discardCount = text.split(discardRule).length - 1;
  const replacementCount = text.split(replacement).length - 1;
  if (discardCount === 0 && replacementCount === 1) return;
  if (discardCount !== 1 || replacementCount !== 0) {
    throw new Error("expected one unpatched ESP-IDF v5.4 GCC-382 discard rule or one clean replacement");
  }
  fs.writeFileSync(linkerScript, text.replace(discardRule, replacement));
}

export function main(argumentsArray = process.argv.slice(2)) {
  if (argumentsArray.length !== 1) {
    console.error("usage: patch-swift-got.mjs <generated-sections.ld>");
    return 2;
  }
  try {
    patchSwiftGOT(argumentsArray[0]);
    return 0;
  } catch (error) {
    console.error(`Swift GOT patch failed: ${error.message}`);
    return 1;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) process.exitCode = main();
