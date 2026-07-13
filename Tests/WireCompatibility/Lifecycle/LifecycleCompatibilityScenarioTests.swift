// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing

/// A declarative scenario that a live interoperability runner can execute for
/// each reference implementation. Keeping the assertions structured prevents
/// lifecycle coverage from degrading into prose-only checklists.
private struct LifecycleScenario {
    enum Participant: String, CaseIterable {
        case modernSwift
        case legacySwift
        case coatyJS
    }

    enum Action: Equatable {
        case start(Participant)
        case stopGracefully(Participant)
        case disconnectNetwork(Participant)
        case reconnectNetwork(Participant)
        case stopBroker
        case startBroker
        case publish(label: String, qos: Int)
        case sendReply(label: String)
        case waitForTimeout
    }

    enum Observation: Equatable {
        case publication(label: String, count: Int)
        case subscriptionRestored
        case orderedPublications([String])
        case deadvertise
        case lastWill
        case noLastWill
        case sessionPresent(Bool)
        case replyAccepted(label: String)
        case replyIgnored(label: String)
        case qos(Int)
    }

    let id: String
    let actions: [Action]
    let observations: [Observation]

    /// The live runner must substitute each implementation as the scenario's
    /// subject; no lifecycle result is inferred from a single implementation.
    var participants: [Participant] { Participant.allCases }
}

private enum LifecycleCompatibilityCatalog {
    static let scenarios: [LifecycleScenario] = [
        LifecycleScenario(
            id: "offline-queueing",
            actions: [
                .start(.modernSwift), .disconnectNetwork(.modernSwift),
                .publish(label: "first", qos: 1), .publish(label: "second", qos: 1),
                .reconnectNetwork(.modernSwift)
            ],
            observations: [
                .orderedPublications(["first", "second"]),
                .publication(label: "first", count: 1),
                .publication(label: "second", count: 1)
            ]
        ),
        LifecycleScenario(
            id: "reconnect-resubscribe",
            actions: [
                .start(.modernSwift), .disconnectNetwork(.modernSwift),
                .reconnectNetwork(.modernSwift), .publish(label: "probe", qos: 0)
            ],
            observations: [.subscriptionRestored, .publication(label: "probe", count: 1)]
        ),
        LifecycleScenario(
            id: "broker-restart",
            actions: [
                .start(.modernSwift), .stopBroker, .startBroker,
                .publish(label: "post-restart-probe", qos: 0)
            ],
            observations: [
                .subscriptionRestored,
                .publication(label: "post-restart-probe", count: 1)
            ]
        ),
        LifecycleScenario(
            id: "graceful-deadvertise",
            actions: [.start(.modernSwift), .stopGracefully(.modernSwift)],
            observations: [.deadvertise, .noLastWill]
        ),
        LifecycleScenario(
            id: "unexpected-disconnect-last-will",
            actions: [.start(.modernSwift), .disconnectNetwork(.modernSwift)],
            observations: [.lastWill]
        ),
        LifecycleScenario(
            id: "clean-session",
            actions: [
                .start(.modernSwift), .disconnectNetwork(.modernSwift),
                .reconnectNetwork(.modernSwift)
            ],
            observations: [.sessionPresent(false), .subscriptionRestored]
        ),
        LifecycleScenario(
            id: "duplicate-reply",
            actions: [
                .start(.modernSwift), .sendReply(label: "original"),
                .sendReply(label: "duplicate")
            ],
            observations: [
                .replyAccepted(label: "original"),
                .replyIgnored(label: "duplicate")
            ]
        ),
        LifecycleScenario(
            id: "late-reply",
            actions: [
                .start(.modernSwift), .waitForTimeout,
                .sendReply(label: "after-timeout")
            ],
            observations: [.replyIgnored(label: "after-timeout")]
        ),
        LifecycleScenario(
            id: "qos-0",
            actions: [.start(.modernSwift), .publish(label: "qos-0-probe", qos: 0)],
            observations: [.publication(label: "qos-0-probe", count: 1), .qos(0)]
        ),
        LifecycleScenario(
            id: "qos-1",
            actions: [.start(.modernSwift), .publish(label: "qos-1-probe", qos: 1)],
            observations: [.publication(label: "qos-1-probe", count: 1), .qos(1)]
        ),
        LifecycleScenario(
            id: "qos-2",
            actions: [.start(.modernSwift), .publish(label: "qos-2-probe", qos: 2)],
            observations: [.publication(label: "qos-2-probe", count: 1), .qos(2)]
        )
    ]
}

@Suite
struct LifecycleCompatibilityScenarioTests {
    @Test
    func testCatalogCoversRequiredFailureAndLifecycleBehavior() {
        let requiredIDs: Set<String> = [
            "offline-queueing", "reconnect-resubscribe", "broker-restart",
            "graceful-deadvertise", "unexpected-disconnect-last-will",
            "clean-session", "duplicate-reply", "late-reply",
            "qos-0", "qos-1", "qos-2"
        ]

        #expect((Set(LifecycleCompatibilityCatalog.scenarios.map { $0.id })) == (requiredIDs))
    }

    @Test

    func testScenarioIdentifiersAreUnique() {
        let ids = LifecycleCompatibilityCatalog.scenarios.map { $0.id }
        #expect((ids.count) == (Set(ids).count))
    }

    @Test

    func testEveryScenarioHasActionsAndWireObservations() {
        for scenario in LifecycleCompatibilityCatalog.scenarios {
            #expect(!(scenario.actions.isEmpty), "\(scenario.id) has no executable actions")
            #expect(!(scenario.observations.isEmpty), "\(scenario.id) has no wire assertions")
            #expect((Set(scenario.participants)) == (Set(LifecycleScenario.Participant.allCases)))
        }
    }

    @Test

    func testEveryPublishDeclaresSupportedQoS() {
        let supportedQoS = Set(0...2)
        for scenario in LifecycleCompatibilityCatalog.scenarios {
            for case let .publish(_, qos) in scenario.actions {
                #expect(supportedQoS.contains(qos), "\(scenario.id) uses invalid QoS \(qos)")
            }
        }
    }

    @Test

    func testQoSScenariosAssertObservedLevel() {
        for qos in 0...2 {
            let scenario = LifecycleCompatibilityCatalog.scenarios.first { $0.id == "qos-\(qos)" }
            #expect((scenario?.observations.contains(.qos(qos))) == (true))
        }
    }

    @Test

    func testGracefulAndUnexpectedShutdownHaveDistinctWireBehavior() {
        let graceful = LifecycleCompatibilityCatalog.scenarios.first { $0.id == "graceful-deadvertise" }
        #expect((graceful?.observations.contains(.deadvertise)) == (true))
        #expect((graceful?.observations.contains(.noLastWill)) == (true))

        let unexpected = LifecycleCompatibilityCatalog.scenarios.first {
            $0.id == "unexpected-disconnect-last-will"
        }
        #expect((unexpected?.observations.contains(.lastWill)) == (true))
        #expect((unexpected?.observations.contains(.deadvertise)) == (false))
    }
}
