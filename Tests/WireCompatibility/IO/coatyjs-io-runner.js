// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

// CoatyJS 2.4.0 IO reference runner for T-021 wire-compatibility captures.
//
// Plays one of several roles selected by the ROLE environment variable so a
// live shell runner can compose JS -> modern and modern -> JS directions:
//
//   associate-source  JS acts as IO router + IO source: registers an IoSource,
//                     publishes an Associate event that associates a
//                     deterministic source+actor on a router-generated IOV
//                     route, then publishes JSON IoValues on that route.
//   actor             JS acts as IO actor: registers an IoActor, observes
//                     IoValues routed to it after association, asserts the
//                     decoded value's shape, and acknowledges application-level.
//   raw-source        Like associate-source but with useRawIoValues=true and a
//                     binary (Uint8Array/Buffer) value, including a NUL byte
//                     and invalid UTF-8 (scenario 3).
//   external-source   Associates on a deterministic non-Coaty external route
//                     and publishes one JSON and one raw value there.
//
// Deterministic object/agent IDs mirror the advertise runner's convention so
// the Axoloty side and the capture can assert exact topics and field values.
// All application-level events are emitted as one JSON object per line on
// stdout for the shell runner / Python verifier to parse.
//
// Note on SensorThings: there is no @coaty/sensor-things package on npm
// (E404) and @coaty/core@2.4.0 does not export SensorThings types. The
// SensorThings wire contract is ordinary Coaty object JSON with an
// `objectType` of `coaty.sensorThings.*`; those scenarios reuse the standard
// Advertise runner rather than this IO runner. No dependency is added.

const { AssociateEvent, Container } = require("@coaty/core");

const brokerUrl = process.env.BROKER_URL;
const namespace = process.env.COATY_NAMESPACE || "wire-compat-v1";
const role = process.env.ROLE || "associate-source";
const contextName = process.env.IO_CONTEXT_NAME || "wire-compat-io-context-1";
const settleMs = Number(process.env.SCENARIO_SETTLE_MS || "1000");
const timeoutMs = Number(process.env.SCENARIO_TIMEOUT_MS || "20000");

// Deterministic identifiers shared with the Axoloty test side and the capture.
const SOURCE_ID = "33333333-3333-4333-8333-333333333333";
const ACTOR_ID = "44444444-4444-4444-8444-444444444444";
// The router+source container's identity is also the ASC publication topic's
// sourceId (`coaty/3/<ns>/ASC-<context>/<routerId>`), so it must be deterministic.
const ROUTER_ID = "55555555-5555-4555-8555-555555555555";
// The actor container needs a *distinct* identity: CoatyJS derives the MQTT
// ClientID from the agent identity, so two containers sharing an identity
// collide and the broker silently disconnects the first one. (The advertise
// runner avoids this by giving its consumer a different identity.)
const ACTOR_AGENT_ID = "66666666-6666-4666-8666-666666666666";
const VALUE_TYPE = "com.coaty.test.WireIoValue";
const UPDATE_RATE = 250;
// A deterministic, non-Coaty external route for scenario 4.
const EXTERNAL_ROUTE = "external/wire-compat-v1/io-external-1";

const report = (state, details = {}) => {
    process.stdout.write(`${JSON.stringify({ state, role, ...details })}\n`);
};

const makeSource = (raw) => ({
    coreType: "IoSource",
    objectType: "coaty.IoSource",
    objectId: SOURCE_ID,
    name: "wire-compat-io-source-1",
    valueType: VALUE_TYPE,
    useRawIoValues: !!raw,
});

const makeActor = (raw) => ({
    coreType: "IoActor",
    objectType: "coaty.IoActor",
    objectId: ACTOR_ID,
    name: "wire-compat-io-actor-1",
    valueType: VALUE_TYPE,
    useRawIoValues: !!raw,
});

// Build the ioContextNodes config for the given local IO points. The framework
// subscribes to Associate events for the context name and wires up routes only
// for points registered here, so each role registers exactly its own points.
const ioContextNodes = (sources, actors) => ({
    [contextName]: { ioSources: sources, ioActors: actors },
});

const buildContainer = (identityId, sources, actors) => Container.resolve({}, {
    common: {
        agentIdentity: {
            coreType: "Identity",
            objectType: "coaty.Identity",
            objectId: identityId,
            name: "coatyjs-io-reference",
        },
        ioContextNodes: ioContextNodes(sources, actors),
    },
    communication: { namespace, shouldAutoStart: false },
});

// Publish an Associate event that associates the deterministic source+actor on
// the given route (or disassociates when route is null). Acting as the router:
// the router identity is this container's identity, so the ASC publication
// topic is coaty/3/<ns>/ASC-<contextName>/<routerId>.
const publishAssociation = (cm, route, isExternal, updateRate) => {
    const event = AssociateEvent.with(
        contextName,
        SOURCE_ID,
        ACTOR_ID,
        route,
        isExternal,
        updateRate,
    );
    cm.publishAssociate(event);
    report("published-associate", {
        ioContextName: contextName,
        ioSourceId: SOURCE_ID,
        ioActorId: ACTOR_ID,
        associatingRoute: route,
        isExternalRoute: !!isExternal,
        updateRate: updateRate ?? undefined,
    });
};

const jsonValues = [
    { label: "scalar", value: 42 },
    { label: "object", value: { temp: 23.5, unit: "C" } },
    { label: "array", value: [1, 2, 3] },
    { label: "null", value: null },
    { label: "int64-max", value: 9223372036854775807 },
    { label: "float", value: 3.14159 },
    { label: "unicode", value: "héllo 世界 ✓" },
    { label: "nested", value: { a: { b: { c: [true, false, null] } } } },
];

// Raw payload including a NUL byte (0x00) and invalid UTF-8 (0xFF 0xFE) that
// must survive a binary transport and must NOT be UTF-8 decoded by the actor.
const rawValue = Buffer.from([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x41, 0x42]);

async function runSource(raw, externalRoute) {
    const source = makeSource(raw);
    const container = buildContainer(ROUTER_ID, [source], []);
    const cm = container.communicationManager;
    report("connecting", { brokerUrl, namespace, role });
    await cm.start({ brokerUrl });
    report("ready");

    const route = externalRoute != null
        ? externalRoute
        : cm.createAssociatingRoute(source);
    publishAssociation(cm, route, externalRoute != null, UPDATE_RATE);

    // The Associate is delivered back through the broker before the local
    // source's route is registered; settle so publishIoValue can resolve it.
    await new Promise(resolve => setTimeout(resolve, settleMs));

    if (raw) {
        cm.publishIoValue(source, rawValue);
        report("published-iovalue", {
            mode: "raw",
            route,
            bytes: Array.from(rawValue),
        });
    } else {
        for (const { label, value } of jsonValues) {
            cm.publishIoValue(source, value);
            report("published-iovalue", { mode: "json", label, route });
        }
    }

    await new Promise(resolve => setTimeout(resolve, settleMs));
    // Disassociate so the actor observes a clean teardown.
    publishAssociation(cm, undefined, false, undefined);
    await new Promise(resolve => setTimeout(resolve, settleMs));
    container.shutdown();
    report("done");
}

async function runActor(raw) {
    const actor = makeActor(raw);
    const container = buildContainer(ACTOR_AGENT_ID, [], [actor]);
    const cm = container.communicationManager;
    report("connecting", { brokerUrl, namespace, role });
    await cm.start({ brokerUrl });
    report("ready");

    let received = 0;
    const expected = Number(process.env.IO_EXPECTED_VALUES || "1");
    const timeout = setTimeout(() => {
        process.stderr.write(`Timed out waiting for IoValues (${received}/${expected})\n`);
        container.shutdown();
        process.exit(1);
    }, timeoutMs);

    const sub = cm.observeIoValue(actor).subscribe(value => {
        received += 1;
        if (raw) {
            const bytes = Array.from(Buffer.from(value));
            report("received-iovalue", { mode: "raw", index: received, bytes });
        } else {
            report("received-iovalue", { mode: "json", index: received, value });
        }
        if (received >= expected) {
            clearTimeout(timeout);
            sub.unsubscribe();
            report("ack", { mode: raw ? "raw" : "json", count: received });
            setTimeout(() => {
                container.shutdown();
                process.exit(0);
            }, 200);
        }
    });
}

async function main() {
    switch (role) {
        case "associate-source":
            return runSource(false, null);
        case "raw-source":
            return runSource(true, null);
        case "external-source":
            return runSource(false, EXTERNAL_ROUTE);
        case "actor":
            return runActor(process.env.IO_RAW === "1");
        default:
            process.stderr.write(`unsupported role: ${role}\n`);
            process.exit(64);
    }
}

main().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exit(1);
});

process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
