// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import { appendFileSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Socket } from "node:net";

export interface ProxyOptions {
  listenPort: number;
  brokerHost: string;
  brokerPort: number;
  controlPort: number;
  connackLog: string;
  readyFile: string;
}

/** Run the controllable MQTT TCP proxy used by lifecycle reconnect tests. */
export async function runProxy(options: ProxyOptions): Promise<void> {
  let severed = false;
  const sockets = new Set<Socket>();
  const dataServer = createServer((client) => {
    if (severed) { client.destroy(); return; }
    const broker = createConnection({ host: options.brokerHost, port: options.brokerPort });
    sockets.add(client); sockets.add(broker);
    let inspected = false;
    broker.on("data", (data) => {
      if (!inspected && data.length >= 4 && data[0] === 0x20) {
        inspected = true;
        appendFileSync(options.connackLog, JSON.stringify({ connack: true, sessionPresent: (data[2]! & 1) !== 0, at: new Date().toISOString() }) + "\n");
      }
      client.write(data);
    });
    client.on("data", (data) => broker.write(data));
    const close = () => { sockets.delete(client); sockets.delete(broker); client.destroy(); broker.destroy(); };
    client.on("error", close); broker.on("error", close); client.on("close", close); broker.on("close", close);
  });
  const controlServer = createServer((socket) => {
    let input = "";
    socket.on("data", (data) => {
      input += data.toString();
      if (!input.includes("\n")) return;
      const command = input.trim();
      if (command === "sever") { severed = true; for (const open of sockets) open.destroy(); sockets.clear(); socket.end("ok\n"); }
      else if (command === "restore") { severed = false; socket.end("ok\n"); }
      else socket.end("unknown command\n");
    });
  });
  await listen(dataServer, options.listenPort);
  await listen(controlServer, options.controlPort);
  writeFileSync(options.readyFile, "ready\n");
  await new Promise<void>(() => undefined);
}

/** Send a sever or restore command to a running lifecycle proxy. */
export function controlProxy(host: string, port: number, command: "sever" | "restore"): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host, port });
    let reply = "";
    socket.once("error", reject);
    socket.on("connect", () => socket.write(command + "\n"));
    socket.on("data", (data) => { reply += data.toString(); });
    socket.on("end", () => reply.trim() === "ok" ? resolve() : reject(new Error(`proxy control replied ${JSON.stringify(reply.trim())}`)));
  });
}

function listen(server: ReturnType<typeof createServer>, port: number): Promise<void> {
  return new Promise((resolve, reject) => { server.once("error", reject); server.listen(port, "0.0.0.0", () => resolve()); });
}
