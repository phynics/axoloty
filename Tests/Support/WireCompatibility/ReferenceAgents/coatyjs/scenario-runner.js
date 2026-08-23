// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { AdvertiseEvent, Container } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL || "mqtt://127.0.0.1:1883";
const scenario = process.env.SCENARIO || "advertise";
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";

if (scenario !== "advertise") {
    process.stderr.write(`unsupported scenario: ${scenario}\n`);
    process.exit(64);
}

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
    communication: {
        namespace,
        shouldAutoStart: false
    }
});

const report = (state, details = {}) => {
    process.stdout.write(`${JSON.stringify({ state, scenario, ...details })}\n`);
};

const finish = () => {
    container.shutdown();
    report("done");
    process.exit(0);
};

report("ready", { brokerUrl, namespace });
container.communicationManager.start({ brokerUrl });

// Publication is deferred by Coaty until the transport is online. Keeping the
// publication synchronous also makes the scenario deterministic for a probe.
container.communicationManager.publishAdvertise(AdvertiseEvent.withObject(fixtureObject));
report("published", { objectId: fixtureObject.objectId });
setTimeout(finish, Number(process.env.SCENARIO_SETTLE_MS || "1000"));

process.on("SIGTERM", finish);
process.on("SIGINT", finish);
