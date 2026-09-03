// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
@testable import Axoloty

extension AxolotyRuntimeTests {
    @Test("external route activation reports capacity exceeded only when the table is genuinely full")
    func externalRouteActivationReportsCapacityExceeded() throws {
        var routes = [
            ExternalRouteRecord(topic: "already/subscribed", referenceCount: 1, state: .subscribed, epoch: 1)
        ]
        let outcome = MQTTBinding.resolveExternalRouteActivation(
            topic: "new/topic",
            started: true,
            routes: &routes,
            capacity: 1,
            transportEpoch: 1
        )
        guard case let .failure(error) = outcome, case let .runtime(code, _) = error else {
            Issue.record("expected a runtime failure, got \(outcome)")
            return
        }
        #expect(code == .capacityExceeded)
        #expect(routes.count == 1)
    }

    @Test("external route activation on a not-started binding reports notStarted, never capacity, never silent success")
    func externalRouteActivationReportsNotStartedAccurately() throws {
        var routes: [ExternalRouteRecord] = []
        // The table is nowhere near capacity here, so a correct implementation
        // cannot attribute the failure to capacity, and must not treat this
        // as a silent success.
        let outcome = MQTTBinding.resolveExternalRouteActivation(
            topic: "new/topic",
            started: false,
            routes: &routes,
            capacity: 64,
            transportEpoch: 1
        )
        guard case let .failure(error) = outcome, case let .runtime(code, _) = error else {
            Issue.record("expected a runtime failure, got \(outcome)")
            return
        }
        #expect(code == .notStarted)
        #expect(code != .capacityExceeded)
        #expect(routes.isEmpty)
    }

    @Test("external route activation reports the transitioning cause, not capacity")
    func externalRouteActivationReportsTransitioningRecord() throws {
        var routes = [
            ExternalRouteRecord(topic: "mid/transition", referenceCount: 1, state: .unsubscribing, epoch: 1)
        ]
        let outcome = MQTTBinding.resolveExternalRouteActivation(
            topic: "mid/transition",
            started: true,
            routes: &routes,
            capacity: 64,
            transportEpoch: 1
        )
        guard case let .failure(error) = outcome, case let .runtime(code, _) = error else {
            Issue.record("expected a runtime failure, got \(outcome)")
            return
        }
        #expect(code == .subscriptionFailed)
        #expect(code != .capacityExceeded)
    }

    @Test("a non-default configured capacity is honoured, not the 64 default")
    func externalRouteActivationHonoursConfiguredCapacity() throws {
        var routes = [
            ExternalRouteRecord(topic: "one", referenceCount: 1, state: .subscribed, epoch: 1)
        ]
        // Capacity 2: a second, distinct route is still admitted.
        let admitted = MQTTBinding.resolveExternalRouteActivation(
            topic: "two",
            started: true,
            routes: &routes,
            capacity: 2,
            transportEpoch: 1
        )
        guard case .success(let resolved) = admitted else {
            Issue.record("expected admission under capacity 2 with 1 existing route, got \(admitted)")
            return
        }
        #expect(resolved.shouldSubscribe)
        #expect(routes.count == 2)

        // The table is now at the configured capacity of 2 (well under the
        // 64 default), so a third distinct route must be rejected.
        let rejected = MQTTBinding.resolveExternalRouteActivation(
            topic: "three",
            started: true,
            routes: &routes,
            capacity: 2,
            transportEpoch: 1
        )
        guard case let .failure(error) = rejected, case let .runtime(code, _) = error else {
            Issue.record("expected capacity failure at the configured bound, got \(rejected)")
            return
        }
        #expect(code == .capacityExceeded)
        #expect(routes.count == 2)
    }

    @Test("MQTTBindingConfiguration rejects an out-of-range external route capacity")
    func mqttBindingConfigurationRejectsInvalidExternalRouteCapacity() {
        #expect(throws: AxolotyError.self) {
            _ = try MQTTBindingConfiguration(maximumExternalRoutes: 0)
        }
        #expect(throws: AxolotyError.self) {
            _ = try MQTTBindingConfiguration(maximumExternalRoutes: 65)
        }
    }

    @Test("MQTTBindingConfiguration accepts and stores a valid external route capacity")
    func mqttBindingConfigurationAcceptsValidExternalRouteCapacity() throws {
        let configuration = try MQTTBindingConfiguration(maximumExternalRoutes: 4)
        #expect(configuration.maximumExternalRoutes == 4)
        let defaulted = try MQTTBindingConfiguration()
        #expect(defaulted.maximumExternalRoutes == 64)
    }
}
