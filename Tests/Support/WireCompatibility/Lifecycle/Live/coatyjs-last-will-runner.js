// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"use strict";

const { Container } = require("@coaty/core");
const identity = {
    coreType: "Identity", objectType: "coaty.Identity",
    objectId: "33333333-3333-4333-8333-333333333333",
    name: "coatyjs-last-will-subject"
};
const container = Container.resolve({}, {
    common: { agentIdentity: identity },
    communication: { namespace: process.env.COATY_NAMESPACE, shouldAutoStart: false }
});

container.communicationManager.start({ brokerUrl: process.env.BROKER_URL }).then(() => {
    process.stdout.write('{"state":"ready","scenario":"unexpected-disconnect-last-will"}\n');
    // The harness sends SIGKILL. No signal handler may invoke graceful shutdown.
    setInterval(() => {}, 60000);
}).catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exit(1);
});
