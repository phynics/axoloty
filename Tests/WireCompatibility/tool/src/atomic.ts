// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { randomUUID } from "crypto";
import { existsSync, renameSync, writeFileSync } from "fs";
import { basename, dirname, resolve as resolvePath } from "path";

/**
 * Write `data` to `destination` atomically so readers never observe a partial
 * document. The data is written to a sibling temporary file in the same
 * directory and then renamed over the destination; the rename is atomic on
 * POSIX filesystems.
 */
export function atomicWriteFileSync(destination: string, data: string, encoding: BufferEncoding = "utf8"): void {
  const resolved = resolvePath(destination);
  const directory = dirname(resolved);
  const temporary = resolvePath(directory, `.${basename(resolved)}.${process.pid}.${randomUUID().slice(0, 8)}.tmp`);
  writeFileSync(temporary, data, encoding);
  renameSync(temporary, resolved);
}

/**
 * Resolve once `file` exists. Polls until the file appears or `timeoutSeconds`
 * elapses, then rejects with a clear error so callers can fail deterministically
 * instead of racing ahead of readiness.
 */
export function waitForFile(file: string, timeoutSeconds: number, pollMilliseconds = 50): Promise<void> {
  return new Promise((resolve, reject) => {
    const resolved = resolvePath(file);
    const deadline = Date.now() + timeoutSeconds * 1000;
    const timer = setInterval(() => {
      if (existsSync(resolved)) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() >= deadline) {
        clearInterval(timer);
        reject(new Error(`${file} did not appear within ${timeoutSeconds}s`));
      }
    }, pollMilliseconds);
  });
}