# Live lifecycle compatibility tests

Run the CoatyJS unexpected-disconnect scenario from the repository root:

```sh
Tests/WireCompatibility/Lifecycle/Live/run-coatyjs-last-will.sh
```

The harness starts an isolated Mosquitto broker and passive capture probe,
waits for the pinned CoatyJS 2.4.0 subject to advertise its identity, and then
sends `SIGKILL`. It passes only when the probe observes the identity
advertisement followed by the broker-issued deadvertise last will, both at
QoS 0 with retain disabled. The JSONL capture is retained under `.testing/wire/`
for diagnosing failures and is ignored by Git.
