// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { Container } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
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
        clearTimeout(timeout);
        subscription.unsubscribe();
        process.stdout.write(`${JSON.stringify({ state: "ack", scenario: "axoloty-advertise", objectId: object.objectId })}\n`);
        container.shutdown();
        setTimeout(() => process.exit(0), 100);
    });
    // `start()` resolves before a newly requested subscription is guaranteed
    // to be acknowledged by the broker. Do not release the producer until the
    // subscription has had a deterministic propagation window.
    setTimeout(() => {
        process.stdout.write(`${JSON.stringify({ state: "ready", scenario: "axoloty-advertise" })}\n`);
    }, 500);
}

run().catch(error => {
    clearTimeout(timeout);
    process.stderr.write(`${error.stack || error}\n`);
    container.shutdown();
    process.exit(1);
});
