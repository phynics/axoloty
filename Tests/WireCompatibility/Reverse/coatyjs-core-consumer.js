// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const {
    CallEvent,
    ChannelEvent,
    CompleteEvent,
    Container,
    DiscoverEvent,
    QueryEvent,
    ResolveEvent,
    RetrieveEvent,
    ReturnEvent
} = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const scenario = process.env.SCENARIO;
const timeoutMs = Number(process.env.SCENARIO_TIMEOUT_MS || "10000");
const object = {
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
            objectId: "33333333-3333-4333-8333-333333333333",
            name: "coatyjs-core-consumer"
        }
    },
    communication: { namespace, shouldAutoStart: false }
});

let subscription;
let finished = false;
const fail = error => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    if (subscription) subscription.unsubscribe();
    container.shutdown();
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
};
const ack = details => {
    if (finished) return;
    finished = true;
    clearTimeout(timeout);
    if (subscription) subscription.unsubscribe();
    process.stdout.write(`${JSON.stringify({ state: "ack", scenario, ...details })}\n`);
    // Give the MQTT client time to flush a correlated response before the
    // container disconnects; the Axoloty producer independently decodes it.
    setTimeout(() => {
        container.shutdown();
        process.exit(0);
    }, 500);
};
const timeout = setTimeout(() => fail(new Error(`Timed out waiting for ${scenario}`)), timeoutMs);

function matchesFixture(candidate) {
    return candidate && candidate.objectId === object.objectId &&
        candidate.objectType === object.objectType && candidate.name === object.name;
}

async function run() {
    await container.communicationManager.start({ brokerUrl });
    const manager = container.communicationManager;
    if (scenario === "deadvertise") {
        subscription = manager.observeDeadvertise().subscribe(event => {
            if (event.data.objectIds.includes(object.objectId)) ack({ objectId: object.objectId });
        }, fail);
    } else if (scenario === "channel") {
        subscription = manager.observeChannel("wire-fixture-channel").subscribe(event => {
            if (matchesFixture(event.data.object) && event.data.privateData.sequence === 7) {
                ack({ channelId: "wire-fixture-channel", objectId: object.objectId });
            }
        }, fail);
    } else if (scenario === "discover-resolve") {
        subscription = manager.observeDiscover().subscribe(event => {
            if (!event.data.matchesObject(object)) return;
            event.resolve(ResolveEvent.withObject(object, undefined, { responder: "coatyjs-2.4.0" }));
            ack({ objectId: object.objectId });
        }, fail);
    } else if (scenario === "query-retrieve") {
        subscription = manager.observeQuery().subscribe(event => {
            if (!event.data.matchesObject(object)) return;
            event.retrieve(RetrieveEvent.withObjects([object], { responder: "coatyjs-2.4.0" }));
            ack({ objectId: object.objectId });
        }, fail);
    } else if (scenario === "query-retrieve-filter-negative") {
        subscription = manager.observeQuery().subscribe(event => {
            const matched = event.data.matchesObject(object);
            if (matched) {
                event.retrieve(RetrieveEvent.withObjects([object], { responder: "coatyjs-2.4.0" }));
            }
            ack({ objectId: object.objectId, matched });
        }, fail);
    } else if (scenario === "query-retrieve-filter-operands") {
        const expected = 4;
        let received = 0;
        subscription = manager.observeQuery().subscribe(event => {
            received++;
            if (received >= expected) {
                ack({ objectId: object.objectId, queriesReceived: received });
            }
        }, fail);
    } else if (scenario === "update-complete") {
        subscription = manager.observeUpdateWithObjectType(object.objectType).subscribe(event => {
            if (!matchesFixture(event.data.object)) return;
            event.complete(CompleteEvent.withObject({ ...object, name: "wire-fixture-completed" }, { responder: "coatyjs-2.4.0" }));
            ack({ objectId: object.objectId });
        }, fail);
    } else if (scenario === "call-return") {
        subscription = manager.observeCall("wire-fixture-operation").subscribe(event => {
            if (event.data.getParameterByName("operand") !== 7) return;
            event.returnEvent(ReturnEvent.withResult({ answer: 49, objectId: object.objectId }, { responder: "coatyjs-2.4.0" }));
            ack({ objectId: object.objectId });
        }, fail);
    } else if (scenario === "duplicate-reply") {
        // Backs the `duplicate-reply` lifecycle scenario: this responder is a
        // legitimate CoatyJS Call responder that (mis)behaves by sending the
        // same correlated Return twice, "original" then "duplicate" 300ms
        // later. Nothing in @coaty/core's CallEvent.returnEvent (see
        // node_modules/@coaty/core/com/call-return.js and
        // communication-manager.js's observeCall handler) prevents a
        // responder from doing this -- there is no one-reply-per-event guard
        // on the wire producer side, confirmed by reading that source before
        // writing this branch. The initiator's behavior (accepting only the
        // first) is therefore a genuine assertion about Axoloty, not a
        // fabricated one about CoatyJS.
        subscription = manager.observeCall("wire-fixture-operation").subscribe(event => {
            if (event.data.getParameterByName("operand") !== 7) return;
            event.returnEvent(ReturnEvent.withResult(
                { answer: 49, objectId: object.objectId, variant: "original" },
                { responder: "coatyjs-2.4.0" }
            ));
            setTimeout(() => {
                event.returnEvent(ReturnEvent.withResult(
                    { answer: 49, objectId: object.objectId, variant: "duplicate" },
                    { responder: "coatyjs-2.4.0" }
                ));
                ack({ objectId: object.objectId });
            }, 300);
        }, fail);
    } else if (scenario === "late-reply") {
        // Backs the `late-reply` lifecycle scenario: this responder withholds
        // its Return well past the point where a well-behaved initiator (see
        // AxolotyLifecycleSubjectTests.lateReply, which uses a 2s response
        // deadline) has already given up and released its response
        // subscription. The Return is still genuinely published to the
        // broker -- LIFECYCLE_LATE_REPLY_DELAY_MS controls exactly how late.
        const delayMs = Number(process.env.LIFECYCLE_LATE_REPLY_DELAY_MS || "4000");
        subscription = manager.observeCall("wire-fixture-operation").subscribe(event => {
            if (event.data.getParameterByName("operand") !== 7) return;
            setTimeout(() => {
                event.returnEvent(ReturnEvent.withResult(
                    { answer: 49, objectId: object.objectId, variant: "late" },
                    { responder: "coatyjs-2.4.0" }
                ));
                ack({ objectId: object.objectId });
            }, delayMs);
        }, fail);
    } else {
        throw new Error(`unsupported scenario: ${scenario}`);
    }
    // Allow the broker to register the scenario-specific subscription before
    // the shell runner releases the Axoloty producer.
    setTimeout(() => process.stdout.write(`${JSON.stringify({ state: "ready", scenario })}\n`), 500);
}

run().catch(fail);
