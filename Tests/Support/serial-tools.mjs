// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";
import { execFileSync } from "node:child_process";

export function configureSerial(device) {
  const stat = fs.statSync(device);
  if (!stat.isCharacterDevice?.()) return false;
  execFileSync("stty", ["-F", device, "115200", "cs8", "-cstopb", "-parenb", "raw", "-echo"]);
  return true;
}

export async function captureSerial(device, deadline, onLine) {
  configureSerial(device);
  const descriptor = fs.openSync(device, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  const started = Date.now();
  const lines = [];
  let pending = "";
  let stopped = false;
  try {
    while (!stopped && Date.now() - started < deadline * 1000) {
      const buffer = Buffer.alloc(4096);
      let count = 0;
      try {
        count = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      } catch (error) {
        if (error.code !== "EAGAIN" && error.code !== "EWOULDBLOCK") throw error;
      }
      if (!count) {
        await new Promise(resolve => setTimeout(resolve, 25));
        continue;
      }
      pending += buffer.subarray(0, count).toString("utf8");
      const completeLines = pending.split(/\r?\n/);
      pending = completeLines.pop();
      for (const line of completeLines) {
        if (!line) continue;
        lines.push(line);
        stopped = onLine(line) === true;
        if (stopped) break;
      }
      // Let another concurrently captured serial port drain its kernel buffer
      // before this high-volume stream reads the next chunk.
      if (!stopped) await new Promise(resolve => setImmediate(resolve));
    }
    if (pending && !stopped) {
      lines.push(pending);
      onLine(pending);
    }
    return lines;
  } finally {
    fs.closeSync(descriptor);
  }
}
