// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const {
    CallEvent,
    Container,
    UpdateEvent
} = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const scenario = process.env.SCENARIO;
const timeoutMs = Number(process.env.SCENARIO_TIMEOUT_MS || "10000");
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
            name: "coatyjs-wire-requester"
        }
    },
    communication: { namespace, shouldAutoStart: false }
});

const fail = error => {
    clearTimeout(timeout);
    process.stderr.write(`${error.stack || error}\n`);
    container.shutdown();
    process.exitCode = 1;
};
const timeout = setTimeout(() => fail(new Error(`Timed out waiting for ${scenario}`)), timeoutMs);

function receive(publish, validate, ack) {
    publish().subscribe(event => {
        try {
            validate(event);
            clearTimeout(timeout);
            process.stdout.write(`${JSON.stringify({ state: ack, scenario })}\n`);
            container.shutdown();
            process.exitCode = 0;
        } catch (error) {
            fail(error);
        }
    }, fail);
}

async function run() {
    await container.communicationManager.start({ brokerUrl });
    const manager = container.communicationManager;
    if (scenario === "update-complete") {
        receive(
            () => manager.publishUpdate(UpdateEvent.withObject(fixtureObject)),
            event => {
                if (event.data.object.objectId !== fixtureObject.objectId ||
                    event.data.object.name !== "wire-fixture-completed" ||
                    event.data.privateData.reference !== "axoloty-modern") {
                    throw new Error("Invalid Complete response from Axoloty");
                }
            },
            "received-complete"
        );
    } else if (scenario === "call-return") {
        receive(
            () => manager.publishCall(CallEvent.with("wire-fixture-operation", {
                operand: 7,
                reference: "coatyjs-2.4.0"
            })),
            event => {
                if (event.data.result.answer !== 49 ||
                    event.data.result.objectId !== fixtureObject.objectId ||
                    event.data.executionInfo.executor !== "axoloty-modern") {
                    throw new Error("Invalid Return response from Axoloty");
                }
            },
            "received-return"
        );
    } else {
        throw new Error(`unsupported scenario: ${scenario}`);
    }
}

run().catch(fail);
