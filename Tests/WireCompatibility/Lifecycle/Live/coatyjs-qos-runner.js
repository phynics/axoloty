// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

// Backs two lifecycle catalog scenarios that are genuinely achievable against
// the pinned CoatyJS 2.4.0 reference agent without a macOS host: qos-0 (a
// straightforward publish observed at the declared QoS) and
// graceful-deadvertise (an explicit `container.shutdown()` publishes
// Deadvertise itself, as opposed to the broker-issued last will covered by
// `coatyjs-last-will-runner.js`, which requires an unexpected SIGKILL).
//
// qos-1 and qos-2 are NOT implemented here, on purpose: pinned
// `@coaty/core@2.4.0`'s `MqttBinding.onJoin` hardcodes
// `this._qos = 0` (see `node_modules/@coaty/core/com/mqtt/mqtt-binding.js`)
// and never reads any QoS option back out of `communication.mqttClientOptions`
// despite that property's own doc comment claiming otherwise. Every publish
// from this reference agent is QoS 0 on the wire regardless of configuration,
// which was confirmed empirically (a "qos-1" attempt here produced a captured
// PUBLISH with `qos: 0`) before writing this comment. See
// `Tests/WireCompatibility/Lifecycle/README.md` for how this is recorded in
// the lifecycle-matrix catalog as `unsupported`, not silently skipped.
const { AdvertiseEvent, Container } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const scenario = process.env.SCENARIO;
const identityId = process.env.IDENTITY_ID;
const objectId = process.env.OBJECT_ID;

const supportedScenarios = new Set(["qos-0", "graceful-deadvertise"]);

if (!supportedScenarios.has(scenario)) {
    process.stderr.write(`unsupported scenario: ${scenario}\n`);
    process.exit(64);
}

const fixtureObject = {
    coreType: "CoatyObject",
    objectType: "com.coaty.test.WireLifecycleProbe",
    objectId,
    name: `wire-lifecycle-${scenario}`,
};

const container = Container.resolve({}, {
    common: {
        agentIdentity: {
            coreType: "Identity",
            objectType: "coaty.Identity",
            objectId: identityId,
            name: `coatyjs-lifecycle-${scenario}`,
        },
    },
    communication: {
        namespace,
        shouldAutoStart: false,
    },
});

const report = (state, details = {}) => {
    process.stdout.write(`${JSON.stringify({ state, scenario, ...details })}\n`);
};

async function run() {
    await container.communicationManager.start({ brokerUrl });
    report("ready");

    if (scenario === "graceful-deadvertise") {
        // A settle window so the "ready" state and the automatic Identity
        // Advertise are both unambiguously separate wire events from the
        // Deadvertise that `shutdown()` publishes next.
        await new Promise(resolve => setTimeout(resolve, 500));
        container.shutdown();
        report("published-deadvertise", { objectId: identityId });
        // `shutdown()` disconnects asynchronously; give the Deadvertise
        // publication time to actually reach the broker before this process
        // exits, mirroring the documented publish-then-settle pattern used
        // throughout this harness (see AxolotyAdvertiseProducerTests.swift).
        await new Promise(resolve => setTimeout(resolve, 500));
        report("done");
        process.exit(0);
        return;
    }

    container.communicationManager.publishAdvertise(AdvertiseEvent.withObject(fixtureObject));
    report("published", { objectId });
    await new Promise(resolve => setTimeout(resolve, Number(process.env.SCENARIO_SETTLE_MS || "1000")));
    container.shutdown();
    report("done");
    process.exit(0);
}

run().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    container.shutdown();
    process.exit(1);
});
