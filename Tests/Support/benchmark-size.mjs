// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const HOST_DEPS = [
  "mqtt-nio", "swift-nio", "swift-nio-ssl", "swift-nio-transport-services",
  "swift-log", "ErrorKit", "swift-json", "IkigaJSON", "swift-docc-plugin",
];

function read(file) {
  try { return fs.readFileSync(file, "utf8"); } catch { return ""; }
}

function readInt(file) {
  return Number(/\d+/.exec(read(file).trim())?.[0] ?? 0);
}

export function parseSize(rawDir, rootDir = "") {
  const size = text => Object.fromEntries(["text", "rodata", "data", "bss"].map(key => [
    key, Number(new RegExp(`\\.${key}\\s+(\\d+)`).exec(text)?.[1] ?? 0),
  ]));
  const libs = text => [...text.matchAll(/\(NEEDED\).*?\[([^\]]+)\]/g)].map(match => match[1]);
  const deps = text => text.split(/\r?\n/).map(line => line.trim().replace(/^[│├└─ ]+/, "").split("@")[0]).filter(Boolean);
  const packageText = read(path.join(rawDir, "package-swift.txt"));
  const targetDeps = name => {
    const pattern = `\\.(?:executable)?Target\\(\\s*name:\\s*"${name}"\\s*,\\s*dependencies:\\s*\\[([^\\]]*)\\]`;
    const match = new RegExp(pattern, "s").exec(packageText);
    return match ? [...match[1].matchAll(/"([^"]+)"/g)].map(m => m[1]) : [];
  };
  const closureCheck = list => !list.some(dep => HOST_DEPS.some(host => dep.toLowerCase().includes(host.toLowerCase())));
  const consumers = {};
  for (const name of ["AxolotyWireConsumer", "AxolotyConsumer"]) {
    const direct = targetDeps(name);
    const closure = name === "AxolotyWireConsumer"
      ? [...new Set(direct)].sort()
      : [...new Set([...direct, ...deps(read(path.join(rawDir, "deps-flatlist.txt")))])].sort();
    consumers[name] = {
      unstrippedBytes: readInt(path.join(rawDir, `wc-unstripped-${name}.txt`)),
      strippedBytes: readInt(path.join(rawDir, `wc-stripped-${name}.txt`)),
      sections: size(read(path.join(rawDir, `llvm-size-${name}.txt`))),
      dynamicLibraries: libs(read(path.join(rawDir, `readelf-d-${name}.txt`))),
      sha256: read(path.join(rawDir, `sha256-${name}.txt`)).trim(),
      dependencyClosure: closure,
      hostDependencyCheck: name === "AxolotyWireConsumer" ? (closureCheck(closure) ? "passed" : "FAILED") : "n/a",
    };
  }
  let commit = "unknown";
  try { commit = execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: rootDir, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch {}
  return { commit, swiftVersion: read(path.join(rawDir, "swift-version.txt")).trim(), buildMode: "release", buildFlags: "-c release -Xswiftc -O -Xswiftc -wmo", consumers };
}
export function compareSize(current, baseline, baselinePath) {
  if (!("consumers" in baseline)) { fs.writeFileSync(baselinePath, `${JSON.stringify(current, null, 2)}\n`); return [0, "BASELINE CREATED"]; }
  const wire = current.consumers?.AxolotyWireConsumer ?? {}; if (wire.hostDependencyCheck === "FAILED") return [1, "BENCHMARK SIZE FAIL: host dependencies leaked into AxolotyWire consumer"];
  const diffs = []; for (const name of ["AxolotyWireConsumer", "AxolotyConsumer"]) { const cur = current.consumers?.[name] ?? {}, base = baseline.consumers?.[name] ?? {};
    for (const field of ["unstrippedBytes", "strippedBytes"]) if (Math.abs((cur[field] ?? 0) - (base[field] ?? 0)) > 64) diffs.push(`  ${name}.${field}: ${base[field] ?? 0} -> ${cur[field] ?? 0} (diff ${(cur[field] ?? 0) - (base[field] ?? 0)} , tolerance +/-64)`);
    for (const sec of ["text", "rodata", "data", "bss"]) if (Math.abs((cur.sections?.[sec] ?? 0) - (base.sections?.[sec] ?? 0)) > 64) diffs.push(`  ${name}.sections.${sec}: ${base.sections?.[sec] ?? 0} -> ${cur.sections?.[sec] ?? 0}`);
    if (name === "AxolotyWireConsumer" && cur.sha256 !== base.sha256) diffs.push(`  ${name}.sha256: ${base.sha256 ?? ""} -> ${cur.sha256 ?? ""} (must match exactly)`);
    if (JSON.stringify([...(cur.dynamicLibraries ?? [])].sort()) !== JSON.stringify([...(base.dynamicLibraries ?? [])].sort())) diffs.push(`  ${name}.dynamicLibraries differ`);
    if (JSON.stringify([...(cur.dependencyClosure ?? [])].sort()) !== JSON.stringify([...(base.dependencyClosure ?? [])].sort())) diffs.push(`  ${name}.dependencyClosure differ`);
    if (cur.hostDependencyCheck !== base.hostDependencyCheck) diffs.push(`  ${name}.hostDependencyCheck: ${base.hostDependencyCheck ?? ""} -> ${cur.hostDependencyCheck ?? ""}`);
  }
  return diffs.length ? [1, `BENCHMARK SIZE FAIL: measurements differ from baseline\n${diffs.join("\n")}\n\nBaseline changes require an explicit update to Benchmarks/Baselines/size-baseline.json.`] : [0, "BENCHMARK SIZE OK"];
}
if (import.meta.url === `file://${process.argv[1]}`) { const mode = process.argv[2]; if (mode === "parse") console.log(JSON.stringify(parseSize(process.argv[3], process.argv[4]), null, 2)); else if (mode === "compare") { const [code, message] = compareSize(JSON.parse(read(process.argv[3])), JSON.parse(read(process.argv[4])), process.argv[4]); console.error(message); process.exit(code); } }
