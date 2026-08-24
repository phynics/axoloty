// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { ChannelEvent, Container } = require("@coaty/core");
const fs = require("node:fs");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const peerAckFile = process.env.WIRE_PEER_ACK_FILE;
const peerAckToken = process.env.WIRE_PEER_ACK_TOKEN;
const expected = {
    coreType: "CoatyObject",
    objectType: "com.coaty.test.WireFixture",
    objectId: "11111111-1111-4111-8111-111111111111",
    name: "wire-fixture"
};

const container = Container.resolve({}, {
    common: { agentIdentity: { name: "coatyjs-reverse-consumer" } },
    communication: { namespace, shouldAutoStart: false }
});

const timeout = setTimeout(() => {
    process.stderr.write("Timed out waiting for Axoloty Advertise\n");
    container.shutdown();
    process.exit(1);
}, Number(process.env.SCENARIO_TIMEOUT_MS || "10000"));

function writePeerAcknowledgement(details = {}) {
    if (!peerAckFile || !peerAckToken) {
        throw new Error("WIRE_PEER_ACK_FILE and WIRE_PEER_ACK_TOKEN are required");
    }
    const marker = {
        version: 1,
        phase: "peer-ack",
        scenario: "axoloty-advertise",
        token: peerAckToken,
        ...details,
    };
    const temporary = `${peerAckFile}.tmp-${process.pid}`;
    fs.writeFileSync(temporary, `${JSON.stringify(marker)}\n`, "utf8");
    fs.renameSync(temporary, peerAckFile);
}

let readySubscription;

async function run() {
    await container.communicationManager.start({ brokerUrl });
    const subscription = container.communicationManager
        .observeAdvertiseWithObjectType(expected.objectType)
        .subscribe(event => {
        const object = event.data.object;
        if (object.objectId !== expected.objectId) {
            return;
        }
        for (const [key, value] of Object.entries(expected)) {
            if (object[key] !== value) {
                throw new Error(`Advertise ${key}: expected ${value}, got ${object[key]}`);
            }
        }
        writePeerAcknowledgement({ objectId: object.objectId });
        clearTimeout(timeout);
        subscription.unsubscribe();
        if (readySubscription) readySubscription.unsubscribe();
        process.stdout.write(`${JSON.stringify({ state: "ack", scenario: "axoloty-advertise", objectId: object.objectId })}\n`);
        container.shutdown();
        setTimeout(() => process.exit(0), 100);
    });
    // CoatyJS does not surface SUBACK. A self-ping after requesting the
    // scenario subscription proves the broker has registered both routes.
    const readyChannel = `wire-fixture-ready-${process.pid}`;
    const token = `ready-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    readySubscription = container.communicationManager.observeChannel(readyChannel).subscribe(event => {
        if (event.data.privateData?.token !== token) return;
        readySubscription.unsubscribe();
        readySubscription = undefined;
        process.stdout.write(`${JSON.stringify({ state: "ready", scenario: "axoloty-advertise" })}\n`);
    });
    container.communicationManager.publishChannel(ChannelEvent.withObject(readyChannel, expected, { token }));
}

run().catch(error => {
    clearTimeout(timeout);
    process.stderr.write(`${error.stack || error}\n`);
    container.shutdown();
    process.exit(1);
});
