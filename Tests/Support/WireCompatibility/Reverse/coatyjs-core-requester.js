// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { Container, DiscoverEvent, QueryEvent } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const scenario = process.env.SCENARIO;
const timeoutMs = Number(process.env.SCENARIO_TIMEOUT_MS || "10000");
const fixtureObjectId = "11111111-1111-4111-8111-111111111111";
const fixtureObjectType = "com.coaty.test.WireFixture";

const container = Container.resolve({}, {
    common: {
        agentIdentity: {
            coreType: "Identity",
            objectType: "coaty.Identity",
            objectId: "22222222-2222-4222-8222-222222222222",
            name: "coatyjs-core-requester"
        }
    },
    communication: { namespace, shouldAutoStart: false }
});

let finished = false;
let timeout;
const fail = error => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    container.shutdown();
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
};
const finish = state => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    process.stdout.write(`${state}\n`);
    setTimeout(() => {
        container.shutdown();
        process.exit(0);
    }, 500);
};

function assertResolve(event) {
    const object = event.data.object;
    if (!object || object.objectId !== fixtureObjectId ||
        object.objectType !== fixtureObjectType || object.name !== "wire-fixture") {
        throw new Error("Resolve did not carry the expected fixture object");
    }
    if (event.data.privateData?.reference !== "coatyswift-modern") {
        throw new Error("Resolve did not carry the expected reference marker");
    }
    finish("received-resolve");
}

function assertRetrieve(event) {
    const object = event.data.objects.find(candidate => candidate.objectId === fixtureObjectId);
    if (!object || object.objectType !== fixtureObjectType || object.name !== "wire-fixture") {
        throw new Error("Retrieve did not carry the expected fixture object");
    }
    if (event.data.privateData?.reference !== "coatyswift-modern" ||
        event.data.privateData?.resultSet !== "deterministic") {
        throw new Error("Retrieve did not carry the expected result markers");
    }
    finish("received-retrieve");
}

async function run() {
    await container.communicationManager.start({ brokerUrl });
    timeout = setTimeout(() => fail(new Error(`Timed out waiting for ${scenario}`)), timeoutMs);
    if (scenario === "discover-resolve") {
        container.communicationManager
            .publishDiscover(DiscoverEvent.withObjectTypes([fixtureObjectType]))
            .subscribe(event => {
                try { assertResolve(event); } catch (error) { fail(error); }
            }, fail);
    } else if (scenario === "query-retrieve") {
        container.communicationManager
            .publishQuery(QueryEvent.withObjectTypes([fixtureObjectType], {}))
            .subscribe(event => {
                try { assertRetrieve(event); } catch (error) { fail(error); }
            }, fail);
    } else {
        throw new Error(`unsupported scenario: ${scenario}`);
    }
}

run().catch(fail);
