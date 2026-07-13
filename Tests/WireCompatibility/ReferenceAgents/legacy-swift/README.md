# Legacy CoatySwift reference runner

This pin is intentionally not represented by a Linux Dockerfile. CoatySwift
2.4.0 depends on Objective-C Apple Foundation sources and is therefore only
buildable on Apple platforms without changing the implementation under test.

A macOS/Xcode runner should checkout commit
`20a97b29832758fb771ac79fd5f7ae36cff69403`, connect to `BROKER_URL`, use
namespace `wire-compat-v1`, execute the `advertise` scenario, and publish the
same deterministic object IDs as `../coatyjs/scenario-runner.js`. Its output
must use the `ready`, `published`, and `done` newline-delimited JSON states.
