#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Replay validated legacy capture bytes to MQTT 3.1.1 without rewriting them."""

import argparse
import base64
import json
import pathlib
import socket
import struct
import sys
import uuid

from validate_legacy_capture import ValidationError, validate


def remaining_length(value):
    output = bytearray()
    while True:
        digit = value % 128
        value //= 128
        output.append(digit | (0x80 if value else 0))
        if not value:
            return bytes(output)


def mqtt_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("!H", len(encoded)) + encoded


def packet(header, body):
    return bytes([header]) + remaining_length(len(body)) + body


def read_exact(connection, length):
    output = bytearray()
    while len(output) < length:
        chunk = connection.recv(length - len(output))
        if not chunk:
            raise RuntimeError("broker closed connection")
        output.extend(chunk)
    return bytes(output)


def read_packet(connection):
    header = read_exact(connection, 1)[0]
    multiplier, length = 1, 0
    for _ in range(4):
        digit = read_exact(connection, 1)[0]
        length += (digit & 0x7f) * multiplier
        if not digit & 0x80:
            return header, read_exact(connection, length)
        multiplier *= 128
    raise RuntimeError("malformed MQTT remaining length")


def connect(host, port, timeout):
    connection = socket.create_connection((host, port), timeout)
    client_id = "legacy-capture-replay-" + uuid.uuid4().hex[:12]
    body = mqtt_string("MQTT") + bytes([4, 2]) + struct.pack("!H", 30) + mqtt_string(client_id)
    connection.sendall(packet(0x10, body))
    header, response = read_packet(connection)
    if header >> 4 != 2 or response != bytes([0, 0]):
        raise RuntimeError("broker rejected connection")
    return connection


def replay(args):
    count = validate(args.capture, args.manifest)
    connection = connect(args.host, args.port, args.timeout)
    packet_id = 0
    with connection, args.capture.open(encoding="utf-8") as stream:
        for line in stream:
            record = json.loads(line)
            mqtt = record["mqtt"]
            payload = base64.b64decode(record["payload"]["bytes"], validate=True)
            qos = mqtt["qos"]
            body = mqtt_string(mqtt["topic"])
            if qos == 1:
                packet_id = packet_id % 65535 + 1
                body += struct.pack("!H", packet_id)
            body += payload
            header = 0x30 | (qos << 1) | int(mqtt["retain"])
            connection.sendall(packet(header, body))
            if qos == 1:
                response_header, response = read_packet(connection)
                if response_header >> 4 != 4 or response != struct.pack("!H", packet_id):
                    raise RuntimeError("invalid PUBACK")
        connection.sendall(packet(0xE0, b""))
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    try:
        count = replay(args)
    except (ValidationError, OSError, RuntimeError) as error:
        print(f"REPLAY FAILED: {error}", file=sys.stderr)
        return 1
    print(f"REPLAYED: {count} byte-exact legacy publications")
    return 0


if __name__ == "__main__":
    sys.exit(main())
