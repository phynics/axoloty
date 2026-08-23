// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { AdvertiseEvent, Container } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const fixtureObject = {
    coreType: "CoatyObject",
    objectType: "com.coaty.test.WireFixture",
    objectId: "11111111-1111-4111-8111-111111111111",
    name: "wire-fixture"
};

const container = Container.resolve({}, {
    common: {
        agentIdentity: {
            coreType: "Identity",
            objectType: "coaty.Identity",
            objectId: "22222222-2222-4222-8222-222222222222",
            name: "coatyjs-wire-reference"
        }
    },
    communication: { namespace, shouldAutoStart: false }
});

const report = (state, details = {}) => {
    process.stdout.write(`${JSON.stringify({ state, scenario: "advertise", ...details })}\n`);
};

async function run() {
    report("connecting", { brokerUrl, namespace });
    await container.communicationManager.start({ brokerUrl });
    report("ready");
    container.communicationManager.publishAdvertise(AdvertiseEvent.withObject(fixtureObject));
    report("published", { objectId: fixtureObject.objectId });
    await new Promise(resolve => setTimeout(resolve, Number(process.env.SCENARIO_SETTLE_MS || "1000")));
    container.shutdown();
    report("done");
}

run().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    container.shutdown();
    process.exitCode = 1;
});
