// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const {
    CallEvent,
    ChannelEvent,
    CompleteEvent,
    Container,
    DeadvertiseEvent,
    DiscoverEvent,
    QueryEvent,
    RetrieveEvent,
    ReturnEvent,
    UpdateEvent,
    ResolveEvent
} = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const scenario = process.env.SCENARIO;
const settleMs = Number(process.env.SCENARIO_SETTLE_MS || "1000");
const fixtureObject = {
    coreType: "CoatyObject",
    objectType: "com.coaty.test.WireFixture",
    objectId: "11111111-1111-4111-8111-111111111111",
    name: "wire-fixture"
};

function makeContainer(objectId, name) {
    return Container.resolve({}, {
        common: {
            agentIdentity: {
                coreType: "Identity",
                objectType: "coaty.Identity",
                objectId,
                name
            }
        },
        communication: { namespace, shouldAutoStart: false }
    });
}

const containers = [];
const report = (state, details = {}) => {
    process.stdout.write(`${JSON.stringify({ state, scenario, ...details })}\n`);
};
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function runOneWay(createEvent, details) {
    const producer = makeContainer(
        "22222222-2222-4222-8222-222222222222",
        "coatyjs-wire-reference"
    );
    containers.push(producer);
    await producer.communicationManager.start({ brokerUrl });
    report("ready", { brokerUrl, namespace });
    createEvent(producer.communicationManager);
    report("published", details);
    await delay(settleMs);
}

async function runDiscoverResolve() {
    const requester = makeContainer(
        "22222222-2222-4222-8222-222222222222",
        "coatyjs-wire-requester"
    );
    const responder = makeContainer(
        "33333333-3333-4333-8333-333333333333",
        "coatyjs-wire-responder"
    );
    containers.push(requester, responder);
    await Promise.all([
        requester.communicationManager.start({ brokerUrl }),
        responder.communicationManager.start({ brokerUrl })
    ]);

    const observed = responder.communicationManager.observeDiscover().subscribe(event => {
        if (!event.data.matchesObject(fixtureObject)) {
            return;
        }
        report("observed-discover", { objectType: fixtureObject.objectType });
        event.resolve(ResolveEvent.withObject(fixtureObject, undefined, { reference: "coatyjs-2.4.0" }));
    });

    report("ready", { brokerUrl, namespace });
    // Coaty's start promise resolves before all deferred MQTT subscriptions are
    // guaranteed to have reached the broker. Give the responder subscription a
    // deterministic propagation window before publishing the lazy request.
    await delay(500);
    await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("timed out waiting for Resolve")), 5000);
        requester.communicationManager
            .publishDiscover(DiscoverEvent.withObjectTypes([fixtureObject.objectType]))
            .subscribe(event => {
                if (!event.data.object || event.data.object.objectId !== fixtureObject.objectId) {
                    return;
                }
                clearTimeout(timeout);
                report("received-resolve", { objectId: event.data.object.objectId });
                resolve();
            }, reject);
        report("published", { objectType: fixtureObject.objectType });
    });
    observed.unsubscribe();
    await delay(settleMs);
}

async function runRequestResponse({ observe, publish, respond, accepts, observedState, receivedState }) {
    const requester = makeContainer(
        "22222222-2222-4222-8222-222222222222",
        "coatyjs-wire-requester"
    );
    const responder = makeContainer(
        "33333333-3333-4333-8333-333333333333",
        "coatyjs-wire-responder"
    );
    containers.push(requester, responder);
    await Promise.all([
        requester.communicationManager.start({ brokerUrl }),
        responder.communicationManager.start({ brokerUrl })
    ]);

    const observed = observe(responder.communicationManager).subscribe(event => {
        if (!accepts(event)) {
            return;
        }
        report(observedState);
        respond(event);
    });

    report("ready", { brokerUrl, namespace });
    await delay(500);
    await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error(`timed out waiting for ${receivedState}`)), 5000);
        publish(requester.communicationManager).subscribe(event => {
            clearTimeout(timeout);
            report(receivedState);
            resolve(event);
        }, reject);
        report("published");
    });
    observed.unsubscribe();
    await delay(settleMs);
}

async function runQueryRetrieve() {
    await runRequestResponse({
        observe: manager => manager.observeQuery(),
        // CoatyJS 2.4.0's object-filter validator dereferences its optional
        // argument, so use the semantically empty filter explicitly.
        publish: manager => manager.publishQuery(QueryEvent.withObjectTypes([fixtureObject.objectType], {})),
        accepts: event => event.data.matchesObject(fixtureObject),
        respond: event => event.retrieve(RetrieveEvent.withObjects(
            [fixtureObject],
            { reference: "coatyjs-2.4.0", resultSet: "deterministic" }
        )),
        observedState: "observed-query",
        receivedState: "received-retrieve"
    });
}

async function runUpdateComplete() {
    const completedObject = { ...fixtureObject, name: "wire-fixture-completed" };
    await runRequestResponse({
        observe: manager => manager.observeUpdateWithObjectType(fixtureObject.objectType),
        publish: manager => manager.publishUpdate(UpdateEvent.withObject(fixtureObject)),
        accepts: event => event.data.object.objectId === fixtureObject.objectId,
        respond: event => event.complete(CompleteEvent.withObject(
            completedObject,
            { reference: "coatyjs-2.4.0" }
        )),
        observedState: "observed-update",
        receivedState: "received-complete"
    });
}

async function runCallReturn() {
    const operation = "wire-fixture-operation";
    await runRequestResponse({
        observe: manager => manager.observeCall(operation),
        publish: manager => manager.publishCall(CallEvent.with(operation, {
            operand: 7,
            reference: "coatyjs-2.4.0"
        })),
        accepts: event => event.data.getParameterByName("operand") === 7,
        respond: event => event.returnEvent(ReturnEvent.withResult(
            { answer: 49, objectId: fixtureObject.objectId },
            { executor: "coatyjs-2.4.0" }
        )),
        observedState: "observed-call",
        receivedState: "received-return"
    });
}

async function run() {
    if (scenario === "deadvertise") {
        await runOneWay(
            manager => manager.publishDeadvertise(
                DeadvertiseEvent.withObjectIds(fixtureObject.objectId)
            ),
            { objectId: fixtureObject.objectId }
        );
    } else if (scenario === "channel") {
        await runOneWay(
            manager => manager.publishChannel(
                ChannelEvent.withObject("wire-fixture-channel", fixtureObject, {
                    sequence: 7,
                    reference: "coatyjs-2.4.0"
                })
            ),
            { channelId: "wire-fixture-channel", objectId: fixtureObject.objectId }
        );
    } else if (scenario === "discover-resolve") {
        await runDiscoverResolve();
    } else if (scenario === "query-retrieve") {
        await runQueryRetrieve();
    } else if (scenario === "update-complete") {
        await runUpdateComplete();
    } else if (scenario === "call-return") {
        await runCallReturn();
    } else {
        throw new Error(`unsupported scenario: ${scenario}`);
    }
    containers.forEach(container => container.shutdown());
    report("done");
}

run().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    containers.forEach(container => container.shutdown());
    process.exitCode = 1;
});
