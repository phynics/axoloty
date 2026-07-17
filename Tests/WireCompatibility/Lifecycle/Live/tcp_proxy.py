#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Controllable TCP proxy for lifecycle network-failure scenarios.

Sits between the Axoloty subject and the Mosquitto broker so an
orchestrating script can sever and restore connectivity at the TCP level
without touching the broker (which the passive capture probe stays
connected to directly). While forwarding, the broker-to-client stream is
inspected for the MQTT CONNACK packet and its session-present flag is
appended to a JSONL log, so the `clean-session` scenario can assert the
decoded MQTT handshake rather than trusting configuration prose.

Control protocol: connect to --control-port and send a single line,
``sever`` or ``restore``; the proxy replies ``ok``. ``sever`` closes every
live pipe and makes new client connections fail immediately; ``restore``
resumes normal forwarding.
"""

import argparse
import asyncio
import json
import time
from pathlib import Path


class Proxy:
    def __init__(self, broker_host, broker_port, connack_log):
        self.broker_host = broker_host
        self.broker_port = broker_port
        self.connack_log = connack_log
        self.severed = False
        self.writers = set()

    def log_connack(self, session_present):
        record = {
            "connack": True,
            "sessionPresent": session_present,
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with self.connack_log.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")

    async def pump(self, reader, writer, inspect_connack=False):
        connack_seen = not inspect_connack
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                if not connack_seen and data and data[0] == 0x20 and len(data) >= 4:
                    # MQTT 3.1.1 CONNACK: 0x20, remaining length 2,
                    # connect-acknowledge flags (bit 0 = session present),
                    # return code.
                    connack_seen = True
                    self.log_connack(session_present=bool(data[2] & 0x01))
                writer.write(data)
                await writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            writer.close()

    async def handle_client(self, client_reader, client_writer):
        if self.severed:
            client_writer.close()
            return
        try:
            broker_reader, broker_writer = await asyncio.open_connection(
                self.broker_host, self.broker_port
            )
        except OSError:
            client_writer.close()
            return
        self.writers.update({client_writer, broker_writer})
        try:
            await asyncio.gather(
                self.pump(client_reader, broker_writer),
                self.pump(broker_reader, client_writer, inspect_connack=True),
            )
        finally:
            self.writers.discard(client_writer)
            self.writers.discard(broker_writer)

    async def handle_control(self, reader, writer):
        line = (await reader.readline()).decode("utf-8", "replace").strip()
        if line == "sever":
            self.severed = True
            for open_writer in list(self.writers):
                open_writer.close()
            self.writers.clear()
        elif line == "restore":
            self.severed = False
        else:
            writer.write(b"unknown command\n")
            await writer.drain()
            writer.close()
            return
        writer.write(b"ok\n")
        await writer.drain()
        writer.close()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--broker-host", default="127.0.0.1")
    parser.add_argument("--broker-port", type=int, default=1883)
    parser.add_argument("--control-port", type=int, required=True)
    parser.add_argument("--connack-log", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path, required=True)
    args = parser.parse_args()

    proxy = Proxy(args.broker_host, args.broker_port, args.connack_log)
    data_server = await asyncio.start_server(
        proxy.handle_client, "127.0.0.1", args.listen_port
    )
    control_server = await asyncio.start_server(
        proxy.handle_control, "127.0.0.1", args.control_port
    )
    args.ready_file.write_text("ready\n", encoding="utf-8")
    async with data_server, control_server:
        await asyncio.gather(data_server.serve_forever(), control_server.serve_forever())


if __name__ == "__main__":
    asyncio.run(main())
