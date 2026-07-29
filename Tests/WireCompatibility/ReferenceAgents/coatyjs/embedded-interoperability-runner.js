// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { AdvertiseEvent, DeadvertiseEvent, DiscoverEvent, ResolveEvent } = require("@coaty/core");
const mqtt = require("mqtt");
const brokerUrl = process.env.BROKER_URL;
const scenario = process.env.SCENARIO;
const ns = "axoloty-embedded";
const agentA = "32400000-0000-4000-8000-000000000001";
const agentB = "32400000-0000-4000-8000-00000000000b";
const objectA = "32400000-0000-4000-8000-000000000002";
const agentJS = "32400000-0000-4000-8000-000000000003";
const correlation = "32400000-0000-4000-8000-000000000004";
const object = { coreType: "CoatyObject", objectType: "coaty.test.Device", objectId: objectA, name: "ESP32-C6 A" };
const topic = (event, source, corr) => `coaty/3/${ns}/${event}/${source}${corr ? `/${corr}` : ""}`;
const report = (state, details = {}) => process.stdout.write(`${JSON.stringify({ state, scenario, ...details })}\n`);

function connect() {
    return new Promise((resolve, reject) => {
        const client = mqtt.connect(brokerUrl, { username: process.env.MQTT_USERNAME, password: process.env.MQTT_PASSWORD, reconnectPeriod: 0, connectTimeout: 5000 });
        client.once("connect", () => resolve(client)); client.once("error", reject);
    });
}
function waitFor(client, prefix, timeout = 60000) {
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { client.removeListener("message", onMessage); reject(new Error(`timed out waiting for ${prefix}`)); }, timeout);
        const onMessage = (received, payload) => {
            if (!received.startsWith(prefix)) return;
            clearTimeout(timer);
            client.removeListener("message", onMessage);
            let decoded;
            try { decoded = JSON.parse(payload); } catch { decoded = payload.toString(); }
            resolve({ received, payload: decoded });
        };
        client.on("message", onMessage);
    });
}
const publish = (client, event, source, data, corr) => new Promise((resolve, reject) => client.publish(topic(event, source, corr), JSON.stringify(data), { qos: 0 }, error => error ? reject(error) : resolve()));
const subscribe = (client, filters) => new Promise((resolve, reject) => client.subscribe(filters, error => error ? reject(error) : resolve()));

async function run() {
    const client = await connect();
    if (scenario === "embedded-requester") {
        await subscribe(client, `coaty/3/${ns}/#`);
        report("ready", { namespace: ns, direction: "coatyjs-requester" });
        const advertise = await waitFor(client, `coaty/3/${ns}/ADV`);
        if (!advertise.received.endsWith(`/${agentA}`)) throw new Error("invalid embedded Advertise source");
        const responsePromise = waitFor(client, topic("RSV", agentA, correlation));
        const deadvertisePromise = waitFor(client, topic("DAD", agentA));
        await publish(client, "DSC", agentJS, DiscoverEvent.withObjectTypes(["coaty.test.Device"]).data.toJsonObject(), correlation);
        report("published", { event: "discover", correlationId: correlation });
        const response = await responsePromise;
        if (response.payload.object?.objectId !== objectA) throw new Error("invalid embedded Resolve object");
        report("received-resolve", { objectId: objectA, correlationId: correlation });
        await deadvertisePromise;
    } else if (scenario === "embedded-responder") {
        await subscribe(client, topic("DSC", "+", "+"));
        report("ready", { namespace: ns, direction: "coatyjs-responder" });
        const discoverPromise = waitFor(client, topic("DSC", agentB, correlation));
        const advertisePayload = AdvertiseEvent.withObject(object).data.toJsonObject();
        const advertiseTimer = setInterval(() => {
            publish(client, "ADV", agentJS, advertisePayload).catch(error => client.emit("error", error));
        }, 1000);
        await publish(client, "ADV", agentJS, advertisePayload);
        report("published", { event: "advertise", objectId: objectA });
        await discoverPromise;
        clearInterval(advertiseTimer);
        await publish(client, "RSV", agentJS, ResolveEvent.withObject(object).data.toJsonObject(), correlation);
        report("published", { event: "resolve", correlationId: correlation });
        await new Promise(resolve => setTimeout(resolve, 500));
        await publish(client, "DAD", agentJS, DeadvertiseEvent.withObjectIds(objectA).data.toJsonObject());
        report("published", { event: "deadvertise", objectId: objectA });
    } else if (scenario === "embedded-last-will-observer") {
        await subscribe(client, `coaty/3/${ns}/#`);
        const advertisePromise = waitFor(client, `coaty/3/${ns}/ADV`);
        const deadvertisePromise = waitFor(client, topic("DAD", agentA));
        report("ready", { namespace: ns, direction: "last-will-observer" });
        await advertisePromise;
        report("observed-advertise", { sourceId: agentA, objectId: objectA });
        const deadvertise = await deadvertisePromise;
        if (!deadvertise.payload.objectIds?.includes(objectA)) throw new Error("invalid embedded last will");
        report("observed-last-will", { sourceId: agentA, objectId: objectA });
    } else if (scenario === "embedded-reconnect-observer") {
        await subscribe(client, "axoloty/test/agent-ready/B");
        const readinessPromise = waitFor(client, "axoloty/test/agent-ready/B");
        report("ready", { namespace: ns, direction: "broker-restart-observer" });
        await readinessPromise;
        report("observed-device-ready", { sourceId: agentB });
    } else throw new Error(`unsupported scenario: ${scenario}`);
    client.end(); report("done");
}
run().catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; });
