#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Capture MQTT 3.1.1 PUBLISH packets as provenance-bearing JSON Lines."""

import argparse
import base64
import json
import os
import socket
import struct
import time
import uuid
from pathlib import Path


def encode_remaining_length(value):
    encoded = bytearray()
    while True:
        digit = value % 128
        value //= 128
        if value:
            digit |= 0x80
        encoded.append(digit)
        if not value:
            return bytes(encoded)


def mqtt_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("!H", len(encoded)) + encoded


def packet(packet_type_and_flags, body):
    return bytes([packet_type_and_flags]) + encode_remaining_length(len(body)) + body


def read_exact(connection, length):
    chunks = bytearray()
    while len(chunks) < length:
        chunk = connection.recv(length - len(chunks))
        if not chunk:
            raise EOFError("broker closed the connection")
        chunks.extend(chunk)
    return bytes(chunks)


def read_packet(connection):
    first = read_exact(connection, 1)[0]
    multiplier = 1
    remaining = 0
    for _ in range(4):
        digit = read_exact(connection, 1)[0]
        remaining += (digit & 0x7f) * multiplier
        if not digit & 0x80:
            return first, read_exact(connection, remaining)
        multiplier *= 128
    raise ValueError("malformed MQTT remaining length")


def parse_publish(first_byte, body):
    topic_length = struct.unpack("!H", body[:2])[0]
    offset = 2
    topic = body[offset:offset + topic_length].decode("utf-8")
    offset += topic_length
    qos = (first_byte >> 1) & 0x03
    packet_id = None
    if qos:
        packet_id = struct.unpack("!H", body[offset:offset + 2])[0]
        offset += 2
    return {
        "topic": topic,
        "payload": body[offset:],
        "qos": qos,
        "retain": bool(first_byte & 0x01),
        "duplicate": bool(first_byte & 0x08),
        "packet_id": packet_id,
    }


def capture_record(message, metadata, sequence):
    return {
        "format": "coaty-wire-capture/v1",
        "producer": {
            "implementation": metadata["producer"],
            "version": metadata["producer_version"],
        },
        "scenario": metadata["scenario"],
        "sequence": sequence,
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mqtt": {
            "topic": message["topic"],
            "qos": message["qos"],
            "retain": message["retain"],
            "duplicate": message["duplicate"],
        },
        "payload": {
            "encoding": "base64",
            "bytes": base64.b64encode(message["payload"]).decode("ascii"),
        },
        "normalizationProfile": metadata["normalization_profile"],
    }


def connect_and_subscribe(args):
    connection = socket.create_connection((args.host, args.port), args.timeout)
    client_id = "coaty-wire-capture-" + uuid.uuid4().hex[:12]
    # A zero keep-alive avoids needing a timer thread in this passive probe.
    variable_header = mqtt_string("MQTT") + bytes([4, 2]) + struct.pack("!H", 0)
    connection.sendall(packet(0x10, variable_header + mqtt_string(client_id)))
    packet_type, body = read_packet(connection)
    if packet_type >> 4 != 2 or len(body) != 2 or body[1] != 0:
        raise RuntimeError("MQTT broker rejected connection")
    connection.sendall(packet(0x82, struct.pack("!H", 1) + mqtt_string(args.topic) + bytes([args.qos])))
    packet_type, body = read_packet(connection)
    if packet_type >> 4 != 9 or len(body) < 3 or body[2] == 0x80:
        raise RuntimeError("MQTT broker rejected subscription")
    connection.settimeout(None)
    return connection


def mark_ready(ready_file):
    if ready_file is None:
        return
    path = Path(ready_file)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text("subscribed\n", encoding="utf-8")
    temporary.replace(path)


def run(args):
    metadata = vars(args)
    connection = connect_and_subscribe(args)
    mark_ready(args.ready_file)
    captured = 0
    with connection, open(args.output, "a", encoding="utf-8") as output:
        while args.count == 0 or captured < args.count:
            first, body = read_packet(connection)
            packet_type = first >> 4
            if packet_type != 3:
                continue
            message = parse_publish(first, body)
            captured += 1
            output.write(json.dumps(capture_record(message, metadata, captured), separators=(",", ":")) + "\n")
            output.flush()
            if message["qos"] == 1:
                connection.sendall(packet(0x40, struct.pack("!H", message["packet_id"])))
            elif message["qos"] == 2:
                raise RuntimeError("QoS 2 capture acknowledgement is not implemented; subscribe at QoS 1")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--topic", default="#")
    parser.add_argument("--qos", type=int, choices=(0, 1), default=1)
    parser.add_argument("--producer", required=True, choices=("coatyjs", "coatyswift-legacy", "coatyswift-modern"))
    parser.add_argument("--producer-version", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--normalization-profile", default="coaty-v1")
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", type=int, default=0, help="Stop after N publications; zero captures until interrupted")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--ready-file", help="Atomically create this file after the broker accepts the subscription")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
